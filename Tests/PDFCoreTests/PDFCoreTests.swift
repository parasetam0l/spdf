import Foundation
import PDFFixtures
import Testing

@testable import PDFCore

@Suite("Owned PDF core")
struct PDFCoreTests {
  @Test func deterministicFixtureRoundTrip() throws {
    let source = try PDFFixtures.onePage()
    let parsed = try PDFParser.parse(source)
    #expect(parsed.pageCount == 1)
    #expect(parsed.graph.objects.count == 5)
    #expect(try PDFWriter.write(parsed.graph) == source)
    #expect(PDFWriter.originalBytes(of: parsed) == source)
  }

  @Test func multiplePagesAndRotationSurviveRewrite() throws {
    let source = try PDFFixtures.threePages()
    let parsed = try PDFParser.parse(source)
    #expect(parsed.pageCount == 3)
    let reopened = try PDFParser.parse(PDFWriter.write(parsed.graph))
    #expect(reopened.pageIDs == parsed.pageIDs)
    #expect(reopened.graph == parsed.graph)
  }

  @Test func unknownNamesStringsAndOpaqueStreamsSurvive() throws {
    let parsed = try PDFParser.parse(PDFFixtures.opaqueBytes())
    guard case .dictionary(let dictionary) = parsed.graph.objects[PDFObjectID(100)],
      case .stream(let stream) = parsed.graph.objects[PDFObjectID(101)]
    else {
      Issue.record("Missing opaque fixture objects")
      return
    }
    #expect(
      dictionary[PDFName(bytes: [0x52, 0x61, 0x77, 0xFF])]
        == .string(Data([0, 0x80, 0xFF, 40, 41])))
    #expect(stream.bytes == Data([0, 0xFF]) + Data("\nendstream\nendobj\nxref\n".utf8))
    let rewritten = try PDFParser.parse(PDFWriter.write(parsed.graph))
    #expect(rewritten.graph.objects[PDFObjectID(100)] == parsed.graph.objects[PDFObjectID(100)])
    #expect(rewritten.graph.objects[PDFObjectID(101)] == parsed.graph.objects[PDFObjectID(101)])
  }

  @Test func changedMetadataPreservesContentAndUnknownObjects() throws {
    let parsed = try PDFParser.parse(PDFFixtures.opaqueBytes())
    var graph = parsed.graph
    guard case .dictionary(var info) = graph.objects[PDFObjectID(100)] else { return }
    info[PDFName("Title")] = .string(Data("Changed fixture title".utf8))
    graph.objects[PDFObjectID(100)] = .dictionary(info)
    let reopened = try PDFParser.parse(PDFWriter.write(graph))
    for (id, value) in parsed.graph.objects where id != PDFObjectID(100) {
      #expect(reopened.graph.objects[id] == value)
    }
    #expect(reopened.pageIDs == parsed.pageIDs)
    #expect(PDFWriter.originalBytes(of: parsed) == parsed.source)
  }

  @Test func xrefOffsetsPointAtActualObjectHeaders() throws {
    let data = try PDFFixtures.threePages()
    let bytes = Array(data)
    let marker = try #require(data.range(of: Data("startxref\n".utf8), options: .backwards))
    var end = try ByteCursor(bytes, offset: marker.upperBound)
    let offset = try end.integer()
    #expect(Array(bytes[offset..<(offset + 4)]) == Array("xref".utf8))
    var cursor = try ByteCursor(bytes, offset: offset)
    try cursor.consume("xref")
    while true {
      cursor.skipTrivia()
      if cursor.matches("trailer") { break }
      let first = try cursor.integer()
      let count = try cursor.integer()
      for number in first..<(first + count) {
        let position = try cursor.integer()
        let generation = try cursor.integer()
        let flag = try cursor.word(maximum: 1)
        if flag == [110] {
          let header = Array("\(number) \(generation) obj".utf8)
          #expect(Array(bytes[position..<(position + header.count)]) == header)
        }
      }
    }
  }

  @Test(arguments: [
    Double.leastNonzeroMagnitude, 1e-30, -1e30, Double.greatestFiniteMagnitude, 0.125, -0.0,
  ])
  func realSerializationHasNoExponentAndRetainsValue(_ value: Double) throws {
    let token = try PDFObjectSerializer.realToken(value)
    #expect(!token.contains("e") && !token.contains("E"))
    #expect(Double(token) == value)
    #expect(try syntax(token) == .real(value))
  }

  @Test func allPDFWhitespaceAndComments() throws {
    #expect(
      try syntax("\0\t\n\u{000C}\r % comment\r\n [true false null] ")
        == .array([.boolean(true), .boolean(false), .null]))
  }

  @Test func literalStringsHandleNestingEscapesAndContinuations() throws {
    #expect(
      try syntax("(a(b)c\\)\\(\\\\\\101\\7\\777\\\r\nz\r\ny)")
        == .string(Data([97, 40, 98, 41, 99, 41, 40, 92, 65, 7, 255, 122, 10, 121])))
  }

  @Test func hexStringsSupportWhitespaceAndOddDigits() throws {
    #expect(try syntax("<0A FF 8>") == .string(Data([10, 255, 128])))
  }

  @Test func escapedNameIdentityAndReferenceLookahead() throws {
    #expect(try syntax("/A#20B#FF") == .name(PDFName(bytes: [65, 32, 66, 255])))
    #expect(
      try syntax("[12 2 R 12 2]")
        == .array([.reference(PDFObjectID(12, generation: 2)), .integer(12), .integer(2)]))
  }

  @Test(arguments: [
    "1e4", "--2", ".", "+", "<GG>", "(unterminated", "<< /A 1 /A 2 >>", "[1 2", "/Bad#QQ",
  ])
  func malformedValuesFailExplicitly(_ input: String) {
    #expect(throws: PDFError.self) { try syntax(input) }
  }

  @Test func truncatedAndBadOffsetFilesAreRejected() throws {
    let fixture = try PDFFixtures.onePage()
    #expect(throws: PDFError.self) { try PDFParser.parse(fixture.dropLast(24)) }
    let marker = try #require(fixture.range(of: Data("startxref\n".utf8), options: .backwards))
    var changed = fixture
    let numberEnd = try #require(changed[marker.upperBound...].firstIndex(of: 10))
    changed.replaceSubrange(marker.upperBound..<numberEnd, with: Data("0".utf8))
    #expect(throws: PDFError.self) { try PDFParser.parse(changed) }
  }

  @Test func overflowingCrossReferenceRangesFailWithoutAllocating() throws {
    var source = try PDFFixtures.onePage()
    let range = try #require(source.range(of: Data("xref\n0 1".utf8)))
    source.replaceSubrange(
      (range.lowerBound + 5)..<range.upperBound, with: Data("9223372036854775807 2".utf8))
    do {
      _ = try PDFParser.parse(source)
      Issue.record("Overflowing xref range was accepted")
    } catch let error as PDFError {
      #expect(error.kind == .limitExceeded)
    }
  }

  @Test func parserAndWriterEnforceResourceLimits() throws {
    let fixture = try PDFFixtures.onePage()
    #expect(throws: PDFError.self) {
      try PDFParser.parse(fixture, limits: PDFLimits(fileBytes: 10))
    }
    #expect(throws: PDFError.self) {
      try PDFParser.parse(fixture, limits: PDFLimits(streamBytes: 2))
    }
    #expect(throws: PDFError.self) {
      try PDFWriter.write(PDFFixtures.graph(), limits: PDFLimits(fileBytes: 20))
    }
    #expect(throws: PDFError.self) { try syntax("[[[[0]]]]", limits: PDFLimits(nesting: 2)) }
    #expect(throws: PDFError.self) { try syntax("/ABCDE", limits: PDFLimits(tokenBytes: 3)) }
  }

  @Test func exactStringLimitsAndExtremeConfigurationAreSafe() throws {
    #expect(try syntax("(abc)", limits: PDFLimits(tokenBytes: 3)) == .string(Data("abc".utf8)))
    #expect(try syntax("<616263>", limits: PDFLimits(tokenBytes: 3)) == .string(Data("abc".utf8)))
    #expect(throws: PDFError.self) { try syntax("(abcd)", limits: PDFLimits(tokenBytes: 3)) }
    #expect(throws: PDFError.self) { try syntax("<61626364>", limits: PDFLimits(tokenBytes: 3)) }
    #expect(
      try PDFParser.parse(PDFFixtures.onePage(), limits: PDFLimits(objects: Int.max)).pageCount == 1
    )
  }

  @Test func structuralKeywordsRequireBoundaries() throws {
    var cursor = try ByteCursor(Array("endobjgarbage".utf8))
    #expect(throws: PDFError.self) { try cursor.keyword("endobj") }
  }

  @Test func cyclicPageTreesAndMissingReferencesFail() throws {
    var cycle = PDFFixtures.graph()
    cycle.objects[PDFObjectID(2)] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(1),
      PDFName("Kids"): .array([.reference(PDFObjectID(2))]),
    ])
    #expect(throws: PDFError.self) { try PDFWriter.write(cycle) }
    var missing = PDFFixtures.graph()
    missing.objects.removeValue(forKey: PDFObjectID(3))
    #expect(throws: PDFError.self) { try PDFWriter.write(missing) }
  }

  @Test func writerRejectsProtectionSignaturesAndConflictingIdentities() throws {
    var protected = PDFFixtures.graph()
    protected.trailer[PDFName("Encrypt")] = .dictionary([:])
    #expect(throws: PDFError.self) { try PDFWriter.write(protected) }
    var signed = PDFFixtures.graph()
    signed.objects[PDFObjectID(6)] = .dictionary([PDFName("Type"): .name(PDFName("Sig"))])
    #expect(throws: PDFError.self) { try PDFWriter.write(signed) }
    var conflicting = PDFFixtures.graph()
    conflicting.objects[PDFObjectID(3, generation: 1)] = .null
    #expect(throws: PDFError.self) { try PDFWriter.write(conflicting) }
  }

  @Test func concurrentParseAndWriteAreIndependent() async throws {
    let fixture = try PDFFixtures.opaqueBytes()
    try await withThrowingTaskGroup(of: Data.self) { group in
      for _ in 0..<8 {
        group.addTask { try PDFWriter.write(PDFParser.parse(fixture).graph) }
      }
      for try await output in group { #expect(output == fixture) }
    }
  }

  private func syntax(_ input: String, limits: PDFLimits = PDFLimits()) throws -> PDFValue {
    var parser = PDFSyntaxParser(cursor: try ByteCursor(Array(input.utf8)), limits: limits)
    let value = try parser.value()
    parser.cursor.skipTrivia()
    #expect(parser.cursor.peek == nil)
    return value
  }
}
