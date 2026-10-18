import Foundation
import PDFFixtures
import Testing

@testable import PDFCore

/// P03-005/P05-019/P06-010..016 evidence: cross-reference streams, object
/// streams, compressed objects, and indirect stream lengths.
@Suite("Cross-reference and object streams")
struct XRefStreamTests {
  @Test func fixtureResolvesCompressedObjectsAndDecodesStreams() throws {
    let data = try PDFFixtures.xrefStreamPages()
    let parsed = try PDFParser.parse(data)
    #expect(parsed.pageCount == 2)
    #expect(parsed.graph.objects.count == 9)
    #expect(parsed.graph.version == "1.7")
    guard case .dictionary(let catalog) = parsed.graph.objects[PDFObjectID(1)],
      case .dictionary(let pageTree) = parsed.graph.objects[PDFObjectID(2)],
      case .stream(let content) = parsed.graph.objects[PDFObjectID(5)],
      case .stream(let objectStream) = parsed.graph.objects[PDFObjectID(8)]
    else {
      Issue.record("Fixture objects missing from the parsed graph")
      return
    }
    #expect(catalog[PDFName("Type")] == .name(PDFName("Catalog")))
    #expect(pageTree[PDFName("Count")] == .integer(2))
    let text = String(decoding: try PDFFilters.decoded(content), as: UTF8.self)
    #expect(text.contains("sPDF Editor xref-stream fixture - page 1"))
    let objectStreamText = String(decoding: try PDFFilters.decoded(objectStream), as: UTF8.self)
    #expect(objectStreamText.contains("/Catalog"))
    #expect(parsed.graph.trailer[PDFName("Root")] == .reference(PDFObjectID(1)))
    #expect(parsed.graph.trailer[PDFName("ID")] != nil)
  }

  @Test func rewriteOfXRefStreamFileReparsesToTheSameGraph() throws {
    let parsed = try PDFParser.parse(PDFFixtures.xrefStreamPages())
    let rewritten = try PDFWriter.write(parsed.graph)
    let reopened = try PDFParser.parse(rewritten)
    #expect(reopened.graph == parsed.graph)
    #expect(reopened.pageIDs == parsed.pageIDs)
    #expect(rewritten.range(of: Data("startxref".utf8), options: .backwards) != nil)
  }

  @Test func objectStreamsAreDecodedOnceAndCached() throws {
    let data = try PDFFixtures.xrefStreamPages()
    let bytes = Array(data)
    let offset = try startxrefOffset(of: data)
    let (entries, _) = try PDFParser.crossReference(in: bytes, at: offset, limits: PDFLimits())
    var loader = PDFObjectLoader(bytes: bytes, entries: entries, limits: PDFLimits())
    _ = try loader.load(number: 2)
    _ = try loader.load(number: 3)
    _ = try loader.load(number: 4)
    _ = try loader.load(number: 5)
    #expect(loader.objectStreamDecodeCount == 1)
  }

  @Test func fieldWidthsDefaultAndValidate() throws {
    #expect(try PDFXRefStream.fieldWidths([:]) == (1, 1, 1))
    #expect(
      try PDFXRefStream.fieldWidths([PDFName("W"): .array([.integer(0), .integer(2), .integer(1)])])
        == (0, 2, 1))
    #expect(throws: PDFError.self) {
      _ = try PDFXRefStream.fieldWidths([PDFName("W"): .array([.integer(1), .integer(2)])])
    }
    #expect(throws: PDFError.self) {
      _ = try PDFXRefStream.fieldWidths([
        PDFName("W"): .array([.integer(1), .integer(9), .integer(1)])
      ])
    }
    #expect(throws: PDFError.self) {
      _ = try PDFXRefStream.fieldWidths([
        PDFName("W"): .array([.integer(0), .integer(0), .integer(0)])
      ])
    }
  }

  @Test func indexRangesDefaultAndStayWithinSize() throws {
    #expect(try PDFXRefStream.indexRanges([:], size: 4, limits: PDFLimits()) == [0..<4])
    #expect(
      try PDFXRefStream.indexRanges(
        [PDFName("Index"): .array([.integer(0), .integer(2), .integer(5), .integer(2)])],
        size: 7, limits: PDFLimits()) == [0..<2, 5..<7])
    #expect(throws: PDFError.self) {
      _ = try PDFXRefStream.indexRanges(
        [PDFName("Index"): .array([.integer(0)])], size: 4, limits: PDFLimits())
    }
    #expect(throws: PDFError.self) {
      _ = try PDFXRefStream.indexRanges(
        [PDFName("Index"): .array([.integer(0), .integer(9)])], size: 4, limits: PDFLimits())
    }
  }

  @Test func compressedEntryIdentityIsEnforced() throws {
    let data = try PDFFixtures.xrefStreamPages()
    let bytes = Array(data)
    let offset = try startxrefOffset(of: data)
    let (parsedEntries, _) = try PDFParser.crossReference(in: bytes, at: offset, limits: PDFLimits())

    var wrongIndex = parsedEntries
    wrongIndex[2] = .compressed(stream: 8, index: 4)
    var loader = PDFObjectLoader(bytes: bytes, entries: wrongIndex, limits: PDFLimits())
    #expect(throws: PDFError.self) { _ = try loader.load(number: 2) }

    var missingStream = parsedEntries
    missingStream[2] = .compressed(stream: 77, index: 0)
    loader = PDFObjectLoader(bytes: bytes, entries: missingStream, limits: PDFLimits())
    #expect(throws: PDFError.self) { _ = try loader.load(number: 2) }

    var compressedStream = parsedEntries
    compressedStream[2] = .compressed(stream: 2, index: 0)
    loader = PDFObjectLoader(bytes: bytes, entries: compressedStream, limits: PDFLimits())
    #expect(throws: PDFError.self) { _ = try loader.load(number: 2) }
  }

  @Test func objectStreamCollectionDoesNotChangeXRefObjectResolution() throws {
    let data = try minimalObjectStreamFile(extendsSelf: true)
    let bytes = Array(data)
    let offset = try startxrefOffset(of: data)
    let (entries, _) = try PDFParser.crossReference(in: bytes, at: offset, limits: PDFLimits())
    var loader = PDFObjectLoader(bytes: bytes, entries: entries, limits: PDFLimits())
    // Resolution is local to the stream selected by the xref, even with
    // collection metadata. Full-graph validation separately rejects this
    // fixture's intentionally cyclic collection.
    #expect(try loader.load(number: 2).value == .dictionary([PDFName("X"): .integer(1)]))
  }

  @Test func objectStreamCollectionsRoundTripAndRejectInvalidRelationships() throws {
    var graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    func stream(parent: PDFValue? = nil) -> PDFValue {
      var dictionary: [PDFName: PDFValue] = [PDFName("Type"): .name(PDFName("ObjStm")),
        PDFName("N"): .integer(0), PDFName("First"): .integer(0), PDFName("Length"): .integer(0)]
      dictionary[PDFName("Extends")] = parent
      return .stream(PDFStream(dictionary: dictionary, bytes: Data()))
    }
    graph.objects[PDFObjectID(20)] = stream()
    graph.objects[PDFObjectID(21)] = stream(parent: .reference(PDFObjectID(20)))
    graph.objects[PDFObjectID(22)] = stream(parent: .reference(PDFObjectID(20)))
    graph.objects[PDFObjectID(23)] = stream(parent: .reference(PDFObjectID(21)))
    let bytes = try PDFWriter.writeCompressed(graph)
    let reopened = try PDFParser.parse(bytes)
    for id in 20...23 { #expect(reopened.graph.objects[PDFObjectID(id)] == graph.objects[PDFObjectID(id)]) }
    #expect(try PDFParser.parse(PDFWriter.write(reopened.graph)).pageIDs == reopened.pageIDs)
    // Include full parse via serialize, which deliberately skips eligibility
    // checks, so corrupt input cannot be hidden by a writer-side rejection.
    for parent in [PDFValue.reference(PDFObjectID(23)), .reference(PDFObjectID(1)),
      .reference(PDFObjectID(999)), .integer(20)] {
      var invalid = graph
      invalid.objects[PDFObjectID(20)] = stream(parent: parent)
      let invalidBytes = try PDFWriter.serialize(invalid)
      do {
        _ = try PDFParser.parse(invalidBytes)
        Issue.record("Invalid object stream collection parsed")
      } catch let error as PDFError { #expect(error.kind == .malformed) }
    }
    // Count links, including cached suffixes, and accept the exact bound.
    for id in 24...25 { graph.objects[PDFObjectID(id)] = stream(parent: .reference(PDFObjectID(id - 1))) }
    try PDFGraphValidation.validateReferences(in: graph, limits: PDFLimits(nesting: 4))
    for id in 26...28 { graph.objects[PDFObjectID(id)] = stream(parent: .reference(PDFObjectID(id - 1))) }
    do {
      try PDFGraphValidation.validateReferences(in: graph, limits: PDFLimits(nesting: 4))
      Issue.record("Excessive object stream collection depth accepted")
    } catch let error as PDFError { #expect(error.kind == .limitExceeded) }
  }

  @Test func unsupportedXRefStreamFiltersFailExplicitly() throws {
    let data = try minimalObjectStreamFile(extendsSelf: false, filter: PDFName("DCTDecode"))
    let bytes = Array(data)
    let offset = try startxrefOffset(of: data)
    do {
      _ = try PDFParser.crossReference(in: bytes, at: offset, limits: PDFLimits())
      Issue.record("Cross-reference stream with an unsupported filter was decoded")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
    }
  }

  @Test func indirectStreamLengthsResolveAndMalformedOnesRecover() throws {
    let payload = Data("indirect length payload".utf8)
    let data = try classicStreamFile(payload: payload, lengthToken: "5 0 R")
    let parsed = try PDFParser.parse(data)
    guard case .stream(let stream) = parsed.graph.objects[PDFObjectID(4)] else {
      Issue.record("Content stream missing")
      return
    }
    #expect(stream.bytes == payload)

    // A missing or non-integer length reference falls back to the bounded
    // endstream/endobj recovery and must still return byte-exact payloads.
    let missing = try classicStreamFile(payload: payload, lengthToken: "7 0 R")
    #expect(try streamBytes(in: missing) == payload)
    let notAnInteger = try classicStreamFile(payload: payload, lengthToken: "1 0 R")
    #expect(try streamBytes(in: notAnInteger) == payload)
  }

  @Test func malformedStreamLengthsRecoverWithinBounds() throws {
    let payload = Data("recovered stream payload".utf8)
    // Missing /Length.
    #expect(try streamBytes(in: classicStreamFile(payload: payload, lengthToken: nil)) == payload)
    // Declared length one byte short of the real boundary.
    #expect(
      try streamBytes(
        in: classicStreamFile(payload: payload, lengthToken: String(payload.count - 1)))
        == payload)
    // Declared length beyond the real boundary.
    #expect(
      try streamBytes(
        in: classicStreamFile(payload: payload, lengthToken: String(payload.count + 8)))
        == payload)
  }

  @Test func recoverySkipsFakeMarkersAndRespectsItsBound() throws {
    let tricky = Data("head endstream junk tail".utf8)
    #expect(try streamBytes(in: classicStreamFile(payload: tricky, lengthToken: nil)) == tricky)

    var broken = try classicStreamFile(payload: Data("no end marker".utf8), lengthToken: nil)
    let marker = try #require(broken.range(of: Data("endstream".utf8), options: .backwards))
    broken.replaceSubrange(marker, with: Data("ENDSTREAM".utf8))
    #expect(throws: PDFError.self) { _ = try PDFParser.parse(broken) }

    let longPayload = Data(repeating: 65, count: 200)
    #expect(throws: PDFError.self) {
      _ = try PDFParser.parse(
        classicStreamFile(payload: longPayload, lengthToken: nil),
        limits: PDFLimits(streamBytes: 8))
    }
  }

  private func streamBytes(in data: Data, limits: PDFLimits = PDFLimits()) throws -> Data {
    let parsed = try PDFParser.parse(data, limits: limits)
    guard case .stream(let stream) = parsed.graph.objects[PDFObjectID(4)] else {
      throw PDFError(.malformed, "Content stream missing")
    }
    return stream.bytes
  }

  // MARK: - Test file assembly

  private func startxrefOffset(of data: Data) throws -> Int {
    let marker = try #require(data.range(of: Data("startxref".utf8), options: .backwards))
    var cursor = try ByteCursor(Array(data), offset: marker.upperBound)
    return try cursor.integer()
  }

  private func minimalObjectStreamFile(
    extendsSelf: Bool, filter: PDFName = PDFName("FlateDecode")
  ) throws -> Data {
    var file = Data("%PDF-1.7\n".utf8)
    let header = Data("2 0\n".utf8)
    var decoded = header
    decoded.append(
      try PDFWriter.serializedValue(.dictionary([PDFName("X"): .integer(1)])))
    var objectStreamDictionary: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("ObjStm")),
      PDFName("N"): .integer(1),
      PDFName("First"): .integer(Int64(header.count)),
      PDFName("Filter"): .name(filter),
    ]
    if extendsSelf {
      objectStreamDictionary[PDFName("Extends")] = .reference(PDFObjectID(1))
    }
    let objectStream = PDFStream(
      dictionary: objectStreamDictionary,
      bytes: filter == PDFName("FlateDecode")
        ? try PDFFilters.encodeFlate(decoded) : Data("opaque".utf8))

    var offsets: [Int: Int] = [:]
    func appendObject(_ number: Int, _ value: PDFValue) throws {
      offsets[number] = file.count
      file.append(Data("\(number) 0 obj\n".utf8))
      file.append(try PDFWriter.serializedValue(value))
      file.append(Data("\nendobj\n".utf8))
    }
    try appendObject(1, .stream(objectStream))

    let xrefOffset = file.count
    func field(_ value: Int, _ width: Int) -> [UInt8] {
      (0..<width).reversed().map { UInt8((value >> (8 * $0)) & 0xFF) }
    }
    var xrefPayload = Data()
    for row in [(0, 0, 0), (1, offsets[1]!, 0), (2, 1, 0), (1, xrefOffset, 0)] {
      xrefPayload.append(contentsOf: field(row.0, 1))
      xrefPayload.append(contentsOf: field(row.1, 2))
      xrefPayload.append(contentsOf: field(row.2, 1))
    }
    let xrefStream = PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XRef")),
        PDFName("Size"): .integer(4),
        PDFName("W"): .array([.integer(1), .integer(2), .integer(1)]),
        PDFName("Index"): .array([.integer(0), .integer(4)]),
        PDFName("Filter"): .name(filter),
      ],
      bytes: filter == PDFName("FlateDecode")
        ? try PDFFilters.encodeFlate(xrefPayload) : xrefPayload)
    try appendObject(3, .stream(xrefStream))
    file.append(Data("startxref\n\(xrefOffset)\n%%EOF\n".utf8))
    return file
  }

  private func classicStreamFile(payload: Data, lengthToken: String?) throws -> Data {
    var file = Data("%PDF-1.7\n".utf8)
    var offsets: [Int: Int] = [:]
    func appendObject(_ number: Int, _ body: Data) {
      offsets[number] = file.count
      file.append(Data("\(number) 0 obj\n".utf8))
      file.append(body)
      file.append(Data("\nendobj\n".utf8))
    }
    appendObject(1, Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
    appendObject(2, Data("<< /Type /Pages /Count 1 /Kids [3 0 R] >>".utf8))
    appendObject(
      3,
      Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>".utf8))
    let lengthEntry = lengthToken.map { " /Length \($0)" } ?? ""
    var streamBody = Data("<<\(lengthEntry) >>\nstream\n".utf8)
    streamBody.append(payload)
    streamBody.append(Data("\nendstream".utf8))
    appendObject(4, streamBody)
    appendObject(5, Data("\(payload.count)".utf8))
    let xrefOffset = file.count
    file.append(Data("xref\n0 6\n0000000000 65535 f \n".utf8))
    for number in 1...5 {
      guard let offset = offsets[number] else { continue }
      let text = String(offset)
      file.append(
        Data((String(repeating: "0", count: max(0, 10 - text.count)) + text + " 00000 n \n").utf8))
    }
    file.append(Data("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
    return file
  }
}
