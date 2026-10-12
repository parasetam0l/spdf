import Foundation
import PDFFixtures
import Testing

@testable import PDFCore

/// P06-007/008/017/020/025..028 evidence: revision chains, hybrid
/// references, newest-revision precedence, linearization hints, and
/// damaged Prev chains.
@Suite("Revision chains")
struct PDFRevisionTests {
  @Test func hybridFixtureResolvesThroughXRefStmAndRewrites() throws {
    let data = try PDFFixtures.hybridReferencePages()
    let parsed = try PDFParser.parse(data)
    #expect(parsed.pageCount == 1)
    guard case .dictionary(let catalog) = parsed.graph.objects[PDFObjectID(1)],
      case .stream(let content) = parsed.graph.objects[PDFObjectID(5)]
    else {
      Issue.record("Hybrid fixture objects missing")
      return
    }
    #expect(catalog[PDFName("Type")] == .name(PDFName("Catalog")))
    let text = String(decoding: try PDFFilters.decoded(content), as: UTF8.self)
    #expect(text.contains("hybrid-reference fixture - page 1"))
    #expect(parsed.graph.trailer[PDFName("XRefStm")] == nil)

    let rewritten = try PDFWriter.write(parsed.graph)
    let reopened = try PDFParser.parse(rewritten)
    #expect(reopened.graph == parsed.graph)
    #expect(reopened.pageIDs == parsed.pageIDs)
  }

  @Test func incrementalFixtureUsesNewestRevisionAndCannotResurrect() throws {
    let data = try PDFFixtures.incrementalUpdate()
    let parsed = try PDFParser.parse(data)
    #expect(parsed.pageCount == 1)
    // Overwritten object 5 resolves to the update revision.
    guard case .stream(let content) = parsed.graph.objects[PDFObjectID(5)] else {
      Issue.record("Updated content stream missing")
      return
    }
    let text = String(decoding: try PDFFilters.decoded(content), as: UTF8.self)
    #expect(text.contains("updated revision"))
    #expect(!text.contains("base revision"))
    // Deleted object 6 cannot resurrect from the older revision.
    #expect(parsed.graph.objects[PDFObjectID(6)] == nil)
    // New object 7 is present and referenced by the newest trailer.
    guard case .dictionary(let info) = parsed.graph.objects[PDFObjectID(7)] else {
      Issue.record("Updated info object missing")
      return
    }
    #expect(info[PDFName("Title")] == .string(Data("updated info".utf8)))
    #expect(parsed.graph.trailer[PDFName("Info")] == .reference(PDFObjectID(7)))
    #expect(parsed.graph.trailer[PDFName("Prev")] == nil)

    let rewritten = try PDFWriter.write(parsed.graph)
    let reopened = try PDFParser.parse(rewritten)
    #expect(reopened.graph == parsed.graph)
  }

  @Test func damagedPrevChainsAndOverlongChainsTerminateSafely() throws {
    let data = try PDFFixtures.incrementalUpdate()
    let updateOffset = try startxrefOffset(of: data)
    let baseOffset = try prevOffset(of: data)
    let baseText = String(baseOffset)
    let updateText = String(updateOffset)

    // Out-of-range Prev pointer.
    var outOfRange = data
    let range = try #require(outOfRange.range(of: Data("/Prev \(baseText)".utf8)))
    outOfRange.replaceSubrange(range, with: Data("/Prev 99999999".utf8))
    #expect(throws: PDFError.self) { _ = try PDFParser.parse(outOfRange) }

    // Prev cycle: the update revision points back at itself.
    var cycle = data
    let cycleRange = try #require(cycle.range(of: Data("/Prev \(baseText)".utf8)))
    cycle.replaceSubrange(cycleRange, with: Data("/Prev \(updateText)".utf8))
    do {
      _ = try PDFParser.parse(cycle)
      Issue.record("Prev cycle was accepted")
    } catch let error as PDFError {
      #expect(error.kind == .malformed)
    }

    // A chain longer than the revision limit fails without loading objects.
    var chain = Data("%PDF-1.7\n".utf8)
    var previous = 0
    for index in 0..<65 {
      let offset = chain.count
      chain.append(Data("xref\n0 1\n0000000000 65535 f \n".utf8))
      let prevEntry = index == 0 ? "" : " /Prev \(previous)"
      chain.append(Data("trailer\n<< /Size 1\(prevEntry) >>\n".utf8))
      previous = offset
    }
    chain.append(Data("startxref\n\(previous)\n%%EOF\n".utf8))
    do {
      _ = try PDFParser.parse(chain)
      Issue.record("Overlong revision chain was accepted")
    } catch let error as PDFError {
      #expect(error.kind == .limitExceeded)
    }
  }

  @Test func hybridConflictingEntriesFailExplicitly() throws {
    let conflicting = try hybridFile(conflict: true)
    do {
      _ = try PDFParser.parse(conflicting)
      Issue.record("Conflicting hybrid entries were accepted")
    } catch let error as PDFError {
      #expect(error.kind == .malformed)
    }
  }

  @Test func linearizationHintsAreDetectedAndNotTrusted() throws {
    // Bogus /T, /O and /E values must not influence object resolution.
    let data = try craftClassicFile([
      (1, "<< /Linearized 1 /L 999999 /O 99 /E 12 /N 9 /T 424242 >>"),
      (2, "<< /Type /Catalog /Pages 3 0 R >>"),
      (3, "<< /Type /Pages /Count 1 /Kids [4 0 R] >>"),
      (4, "<< /Type /Page /Parent 3 0 R /MediaBox [0 0 612 792] >>"),
    ])
    let parsed = try PDFParser.parse(data)
    #expect(parsed.pageCount == 1)
    guard case .dictionary(let hints) = parsed.graph.objects[PDFObjectID(1)] else {
      Issue.record("Linearization dictionary missing")
      return
    }
    #expect(hints[PDFName("Linearized")] == .integer(1))
    // Detection for the write gate: a full rewrite refuses linearized input.
    do {
      _ = try PDFWriter.write(parsed.graph)
      Issue.record("Linearized graph was rewritten without a dedicated policy")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
    }
  }

  // MARK: - Test file assembly

  private func startxrefOffset(of data: Data) throws -> Int {
    let marker = try #require(data.range(of: Data("startxref".utf8), options: .backwards))
    var cursor = try ByteCursor(Array(data), offset: marker.upperBound)
    return try cursor.integer()
  }

  private func prevOffset(of data: Data) throws -> Int {
    let marker = try #require(data.range(of: Data("/Prev ".utf8), options: .backwards))
    var cursor = try ByteCursor(Array(data), offset: marker.upperBound)
    return try cursor.integer()
  }

  private func craftClassicFile(_ objects: [(Int, String)]) throws -> Data {
    var file = Data("%PDF-1.7\n".utf8)
    var offsets: [Int: Int] = [:]
    for (number, body) in objects {
      offsets[number] = file.count
      file.append(Data("\(number) 0 obj\n\(body)\nendobj\n".utf8))
    }
    let count = (objects.map(\.0).max() ?? 0) + 1
    let xrefOffset = file.count
    file.append(Data("xref\n0 \(count)\n0000000000 65535 f \n".utf8))
    for number in 1..<count {
      let text = String(offsets[number] ?? 0)
      file.append(Data((String(repeating: "0", count: max(0, 10 - text.count)) + text + " 00000 n \n").utf8))
    }
    file.append(Data("trailer\n<< /Size \(count) /Root 2 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
    return file
  }

  /// Minimal hybrid file: object 1 is a plain dictionary described by both
  /// the classic table and the XRefStm stream; with `conflict` the stream
  /// calls it free while the table marks it in-use.
  private func hybridFile(conflict: Bool) throws -> Data {
    var file = Data("%PDF-1.7\n".utf8)
    let objectOffset = file.count
    file.append(Data("1 0 obj\n<< /X 1 >>\nendobj\n".utf8))
    let xrefStreamOffset = file.count
    func field(_ value: Int, _ width: Int) -> [UInt8] {
      (0..<width).reversed().map { UInt8((value >> (8 * $0)) & 0xFF) }
    }
    var payload = Data()
    for row in [
      [0, 0, 65_535],
      conflict ? [0, 0, 0] : [1, objectOffset, 0],
      [1, xrefStreamOffset, 0],
    ] {
      payload.append(contentsOf: field(row[0], 1))
      payload.append(contentsOf: field(row[1], 2))
      payload.append(contentsOf: field(row[2], 1))
    }
    let stream = PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XRef")),
        PDFName("Size"): .integer(3),
        PDFName("W"): .array([.integer(1), .integer(2), .integer(1)]),
        PDFName("Index"): .array([.integer(0), .integer(3)]),
      ], bytes: payload)
    file.append(Data("2 0 obj\n".utf8))
    file.append(try PDFWriter.serializedValue(.stream(stream)))
    file.append(Data("\nendobj\n".utf8))
    let tableOffset = file.count
    func row(_ offset: Int) -> String {
      let text = String(offset)
      return String(repeating: "0", count: max(0, 10 - text.count)) + text + " 00000 n \n"
    }
    file.append(Data("xref\n0 3\n0000000000 65535 f \n".utf8))
    file.append(Data(row(objectOffset).utf8))
    file.append(Data(row(xrefStreamOffset).utf8))
    file.append(
      Data(
        "trailer\n<< /Size 3 /XRefStm \(xrefStreamOffset) >>\nstartxref\n\(tableOffset)\n%%EOF\n"
          .utf8))
    return file
  }
}
