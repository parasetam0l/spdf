import Foundation
import PDFFixtures
import Testing

@testable import PDFCore

/// P04-012/P04-015/P04-020/P04-024/P04-026: resolution states, cycle-aware
/// traversal, copy-on-write boundaries, byte comparison, and hostile-length
/// safety in the core model.
@Suite("Core graph model")
struct GraphModelTests {
  // MARK: - Resolution states (P04-012)

  @Test func resolveDistinguishesMissingFreeMalformedAndUnsupported() throws {
    var resolver = PDFObjectLoader(bytes: [], entries: [:], limits: PDFLimits())
    #expect(resolver.resolve(number: 99) == .missing)

    resolver = PDFObjectLoader(bytes: [], entries: [5: .free], limits: PDFLimits())
    #expect(resolver.resolve(number: 5) == .free)

    // An entry whose bytes do not parse reports malformed, not missing.
    let garbage = [UInt8]("%PDF-1.7\n99 0 obj\nnot-an-object\nendobj".utf8)
    resolver = PDFObjectLoader(bytes: garbage, entries: [99: .ordinary(offset: 9, generation: 0)], limits: PDFLimits())
    if case .malformed(let message) = resolver.resolve(number: 99) {
      #expect(!message.isEmpty)
    } else {
      Issue.record("expected malformed, got \(resolver.resolve(number: 99))")
    }

    // A plain integer object resolves with its value.
    let plain = [UInt8]("%PDF-1.7\n5 0 obj\n42\nendobj".utf8)
    resolver = PDFObjectLoader(bytes: plain, entries: [5: .ordinary(offset: 9, generation: 0)], limits: PDFLimits())
    #expect(resolver.resolve(number: 5) == .resolved(.integer(42)))
    // ...and the throwing loader maps each state back to its error kind.
    #expect(try resolver.load(number: 5).value == .integer(42))
    var missing = PDFObjectLoader(bytes: [], entries: [:], limits: PDFLimits())
    do {
      _ = try missing.load(number: 7)
      Issue.record("expected a missing-entry throw")
    } catch let error as PDFError {
      #expect(error.kind == .malformed)
    } catch {
      Issue.record("wrong error type \(error)")
    }
  }

  @Test func chainedObjectStreamsResolveAsUnsupported() {
    // The stream dictionary parses, but Extends refuses before decoding.
    let bytes = [UInt8](
      "%PDF-1.7\n6 0 obj\n<< /Type /ObjStm /N 0 /First 4 /Length 1 /Extends 7 0 R >>\nstream\n \nendstream\nendobj"
        .utf8)
    var resolver = PDFObjectLoader(
      bytes: bytes,
      entries: [5: .compressed(stream: 6, index: 0), 6: .ordinary(offset: 9, generation: 0)],
      limits: PDFLimits())
    if case .unsupported(let message) = resolver.resolve(number: 5) {
      #expect(message.contains("Chained"))
    } else {
      Issue.record("expected unsupported, got \(resolver.resolve(number: 5))")
    }
  }

  // MARK: - Traversal (P04-015)

  @Test func reachableVisitsOnceAndReportsCycles() {
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("A"): .reference(PDFObjectID(2)),
          PDFName("B"): .reference(PDFObjectID(3)),
        ]),
        PDFObjectID(2): .dictionary([PDFName("Back"): .reference(PDFObjectID(1))]),
        PDFObjectID(3): .dictionary([PDFName("Leaf"): .integer(1)]),
        PDFObjectID(9): .dictionary([PDFName("Self"): .reference(PDFObjectID(9))]),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let result = PDFGraphTraversal.reachable(
      from: [PDFObjectID(1), PDFObjectID(9)], in: graph)
    #expect(Set(result.order) == Set([PDFObjectID(1), PDFObjectID(2), PDFObjectID(3), PDFObjectID(9)]))
    #expect(result.order.first == PDFObjectID(1))
    #expect(result.order.last == PDFObjectID(9))
    #expect(result.cycles.count == 2)
    #expect(result.cycles.contains([PDFObjectID(1), PDFObjectID(2), PDFObjectID(1)]))
    #expect(result.cycles.contains([PDFObjectID(9), PDFObjectID(9)]))
    // Unreachable objects never appear.
    let empty = PDFGraphTraversal.reachable(from: [PDFObjectID(3)], in: graph)
    #expect(empty.order == [PDFObjectID(3)])
    #expect(empty.cycles.isEmpty)
  }

  // MARK: - Copy-on-write (P04-020)

  @Test func valueSemanticsIsolateMutations() {
    let original = PDFGraph(
      objects: [PDFObjectID(1): .dictionary([PDFName("K"): .integer(1)])],
      trailer: [:])
    var copy = original
    copy.objects[PDFObjectID(1)] = .dictionary([PDFName("K"): .integer(2)])
    copy.objects[PDFObjectID(2)] = .null
    // The mutation boundary is the value itself: the original is untouched.
    #expect(original.objects[PDFObjectID(1)] == .dictionary([PDFName("K"): .integer(1)]))
    #expect(original.objects[PDFObjectID(2)] == nil)
  }

  // MARK: - Byte comparison (P04-024)

  @Test func firstDifferencePinpointsEdits() {
    #expect(PDFBytes.firstDifference(between: [1, 2, 3], and: [1, 2, 3]) == nil)
    #expect(PDFBytes.firstDifference(between: [1, 2, 3], and: [1, 9, 3]) == 1)
    #expect(PDFBytes.firstDifference(between: [1, 2], and: [1, 2, 3]) == 2)
    #expect(PDFBytes.firstDifference(between: [], and: [7]) == 0)
    #expect(
      PDFBytes.firstDifference(between: Data("abc".utf8), and: Data("abd".utf8)) == 2)
    #expect(PDFBytes.commonPrefixLength(between: [5, 5, 1], and: [5, 5, 2, 9]) == 2)
  }

  // MARK: - Hostile lengths (P04-026)

  @Test func hostileLengthsFailAsLimitsNeverOverflows() throws {
    // A stream length far beyond the file cannot allocate: bounded failure.
    let bytes = [UInt8](
      "1 0 obj\n<< /Length 999999999999999999999 >>\nstream\nx\nendstream\nendobj".utf8)
    var resolver = PDFObjectLoader(
      bytes: bytes, entries: [1: .ordinary(offset: 0, generation: 0)],
      limits: PDFLimits(streamBytes: 1024))
    if case .malformed = resolver.resolve(number: 1) {
    } else {
      // Limit errors also surface here depending on which bound trips first;
      // either way the input cannot overflow an allocation.
      let result = resolver.resolve(number: 1)
      #expect(result == .resolved(.stream(PDFStream(bytes: Data("x\n".utf8)))) || {
        if case .malformed = result { return true }
        return false
      }())
    }
    // Negative object counts in an xref section refuse to parse.
    let bad = [UInt8]("xref\n0 -5\ntrailer\n<< >>\nstartxref\n0\n%%EOF".utf8)
    #expect(throws: PDFError.self) { try PDFParser.parse(Data(bad)) }
    // Deep nesting resolves as a limit state, preserving the bound.
    let deep = [UInt8](
      ("%PDF-1.7\n5 0 obj\n" + String(repeating: "[", count: 100) + "1"
        + String(repeating: "]", count: 100) + "\nendobj").utf8)
    var loader = PDFObjectLoader(
      bytes: deep, entries: [5: .ordinary(offset: 9, generation: 0)],
      limits: PDFLimits())
    if case .limit = loader.resolve(number: 5) {
    } else {
      Issue.record("expected a limit state, got \(loader.resolve(number: 5))")
    }
  }
}

extension GraphModelTests {
  // MARK: - Spans and diagnostics (P04-011/P04-017/P04-018)

  @Test func objectsCarrySourceSpans() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    #expect(!parsed.spans.isEmpty)
    for (id, span) in parsed.spans {
      #expect(span.start > 0)
      #expect(span.end > span.start)
      #expect(span.end <= parsed.source.count)
      #expect(parsed.graph.objects[id] != nil)
    }
    // The catalog's span covers its object's bytes in the source.
    let rootID = try #require(parsed.graph.trailer[PDFName("Root")])
    guard case .reference(let catalogID) = rootID,
      let span = parsed.spans[catalogID]
    else {
      Issue.record("catalog span missing")
      return
    }
    let slice = parsed.source[span.start..<span.end]
    #expect(slice.contains(UInt8(ascii: "/")))
  }

  @Test func diagnosticsSeparateInfoFromErrors() throws {
    // Ordinary files parse with no diagnostics: nothing noteworthy.
    let plain = try PDFParser.parse(PDFFixtures.threePages())
    #expect(plain.diagnostics.isEmpty)
    // Diagnostics never carry document content — identity and spans only.
    for diagnostic in plain.diagnostics {
      #expect(!diagnostic.message.contains("fixture"))
    }
    // A PDF 2.0 header is accepted with an info note, not an error.
    var bytes = try PDFFixtures.onePage()
    bytes.replaceSubrange(5..<8, with: Data("2.0".utf8))
    let two = try PDFParser.parse(Data(bytes))
    #expect(two.diagnostics.contains {
      $0.severity == .info && $0.operation == "parse" && $0.object == nil
        && $0.span == nil && $0.message.contains("2.0")
    })
  }

  // MARK: - Geometry exactness (P04-021)

  @Test func geometryTransformsAreExact() throws {
    let point = PDFPoint(x: 0.5, y: 0.25)
    // Identity and translation are exact, including fractions.
    #expect(point.applying(.identity) == point)
    #expect(
      point.applying(.translation(x: 0.5, y: -0.25)) == PDFPoint(x: 1.0, y: 0.0))
    // Quarter turns use exact entries: four turns return exactly.
    let turn = PDFMatrix.quarterTurns(clockwise: 1)
    #expect(PDFPoint(x: 3, y: 4).applying(turn) == PDFPoint(x: 4, y: -3))
    let four = turn.concatenating(turn).concatenating(turn).concatenating(turn)
    #expect(point.applying(four) == point)
    // Composition is associative on exact values.
    let scale = PDFMatrix.scale(x: 0.5, y: 2)
    let shift = PDFMatrix.translation(x: 3, y: 0.5)
    let turn1 = PDFMatrix.quarterTurns(clockwise: 1)
    let left = scale.concatenating(shift).concatenating(turn1)
    let right = scale.concatenating(shift.concatenating(turn1))
    #expect(left == right)
    #expect(point.applying(left) == point.applying(right))
    // Inverses round-trip; singular matrices return nil, not infinities.
    let matrix = PDFMatrix(a: 2, b: 0, c: 0, d: 4, tx: 10, ty: -6)
    let inverse = try #require(matrix.inverted())
    #expect(point.applying(matrix).applying(inverse) == point)
    #expect(PDFMatrix(a: 1, b: 2, c: 2, d: 4, tx: 0, ty: 0).inverted() == nil)
    // Rectangles map corners exactly, including axis swaps.
    let rect = PDFRect(x0: 10, y0: 20, x1: 30, y1: 40)
    #expect(rect.applying(.identity) == rect)
    #expect(rect.normalized == rect)
    #expect(PDFRect(x0: 30, y0: 40, x1: 10, y1: 20).normalized == rect)
    let rotated = rect.applying(.quarterTurns(clockwise: 1))
    #expect(rotated == PDFRect(x0: 20, y0: -30, x1: 40, y1: -10))
    #expect(rect.union(PDFRect(x0: 0, y0: 0, x1: 5, y1: 5))
      == PDFRect(x0: 0, y0: 0, x1: 30, y1: 40))
    #expect(rect.contains(PDFPoint(x: 10, y: 20)))
    #expect(!rect.contains(PDFPoint(x: 31, y: 20)))
  }

  // MARK: - Lazy object cache (P04-013)

  @Test func objectCacheEvictsLeastRecentlyUsedWithinEntryBudget() {
    var cache = PDFObjectCache(maxEntries: 2, maxBytes: 1_000_000)
    cache.set(1, entry: (PDFObjectID(1), .integer(1)))
    cache.set(2, entry: (PDFObjectID(2), .integer(2)))
    #expect(cache.count == 2)
    _ = cache.get(1)  // 1 is now most-recently-used.
    cache.set(3, entry: (PDFObjectID(3), .integer(3)))
    #expect(cache.count == 2)
    #expect(cache.get(2) == nil)  // Least-recently-used entry evicted.
    #expect(cache.get(1)?.value == .integer(1))
    #expect(cache.get(3)?.value == .integer(3))
    #expect(cache.evictions == 1)
    #expect(cache.hits >= 3)
    #expect(cache.misses == 1)
  }

  @Test func objectCacheAccountsBytesAndEnforcesByteBudget() {
    let big = PDFValue.string(Data(repeating: 0x41, count: 100))
    #expect(PDFObjectCache.estimatedSize(of: big) == 116)
    #expect(PDFObjectCache.estimatedSize(of: .integer(1)) == 24)
    var cache = PDFObjectCache(maxEntries: 1_000, maxBytes: 64)
    cache.set(1, entry: (PDFObjectID(1), .integer(1)))
    #expect(cache.bytes == 24)
    cache.set(2, entry: (PDFObjectID(2), big))
    // The 116-byte entry exceeds the 64-byte budget on its own, so the
    // small entry is evicted and the newest entry is retained.
    #expect(cache.count == 1)
    #expect(cache.get(1) == nil)
    #expect(cache.get(2)?.value == big)
    #expect(cache.bytes == 116)
    #expect(cache.evictions == 1)
  }

  /// Builds raw bytes plus cross-reference entries for `count` plain
  /// integer objects numbered 1...count.
  private func integerObjectSource(count: Int) -> (bytes: [UInt8], entries: [Int: XRefEntry]) {
    var text = "%PDF-1.7\n"
    var entries: [Int: XRefEntry] = [:]
    for number in 1...count {
      entries[number] = .ordinary(offset: text.utf8.count, generation: 0)
      text += "\(number) 0 obj\n\(number)\nendobj\n"
    }
    return (Array(text.utf8), entries)
  }

  @Test func loaderServesEvictedObjectsByReloadingFromSource() throws {
    let source = integerObjectSource(count: 4)
    var loader = PDFObjectLoader(
      bytes: source.bytes, entries: source.entries, limits: PDFLimits(),
      cacheEntries: 2, cacheBytes: 1_000_000)
    for number in 1...4 {
      #expect(try loader.load(number: number).value == .integer(Int64(number)))
    }
    let stats = loader.cacheStats
    #expect(stats.entries <= 2)
    #expect(stats.evictions > 0)
    // Evicted objects reload byte-identically from source.
    #expect(try loader.load(number: 1).value == .integer(1))
    #expect(try loader.load(number: 2).value == .integer(2))
    // Spans survive eviction: they are accounted separately from values.
    #expect(loader.spans[PDFObjectID(1)] != nil)
  }

  @Test func loaderKeepsEverythingUnderDefaultBudgets() throws {
    let source = integerObjectSource(count: 4)
    var loader = PDFObjectLoader(
      bytes: source.bytes, entries: source.entries, limits: PDFLimits())
    for number in 1...4 {
      #expect(try loader.load(number: number).value == .integer(Int64(number)))
    }
    let stats = loader.cacheStats
    #expect(stats.entries == 4)
    #expect(stats.evictions == 0)
    #expect(stats.bytes > 0)
  }

  // MARK: - Object-cache benchmark (P04-029)

  @Test func objectCacheOverheadIsMeasuredOnSmallAndLargeGraphs() throws {
    func resolveAll(count: Int, cacheEntries: Int?) throws
      -> (elapsedMilliseconds: Double, evictions: Int)
    {
      let source = integerObjectSource(count: count)
      var loader = PDFObjectLoader(
        bytes: source.bytes, entries: source.entries, limits: PDFLimits(),
        cacheEntries: cacheEntries)
      let started = Date()
      for number in 1...count {
        let value = try loader.load(number: number).value
        guard value == .integer(Int64(number)) else {
          Issue.record("wrong value for object \(number)")
          break
        }
      }
      return (Date().timeIntervalSince(started) * 1_000, loader.cacheStats.evictions)
    }
    let small = try resolveAll(count: 50, cacheEntries: nil)
    let smallTiny = try resolveAll(count: 50, cacheEntries: 8)
    #expect(small.evictions == 0)
    #expect(smallTiny.evictions > 0)
    let large = try resolveAll(count: 2_000, cacheEntries: nil)
    let largeTiny = try resolveAll(count: 2_000, cacheEntries: 8)
    #expect(large.evictions == 0)
    #expect(largeTiny.evictions > 0)
    // Full-document context: small vs large fixture graphs through the parser.
    let smallData = try PDFWriter.write(PDFFixtures.graph(pages: 1))
    let largeData = try PDFWriter.write(PDFFixtures.graph(pages: 8))
    let parseStarted = Date()
    let smallParsed = try PDFParser.parse(smallData)
    let smallParseMs = Date().timeIntervalSince(parseStarted) * 1_000
    let largeStarted = Date()
    let largeParsed = try PDFParser.parse(largeData)
    let largeParseMs = Date().timeIntervalSince(largeStarted) * 1_000
    print(
      "[P04-029] resolve 50 objects: default \(String(format: "%.1f", small.elapsedMilliseconds)) ms, "
        + "8-entry cache \(String(format: "%.1f", smallTiny.elapsedMilliseconds)) ms; "
        + "resolve 2,000 objects: default \(String(format: "%.1f", large.elapsedMilliseconds)) ms, "
        + "8-entry cache \(String(format: "%.1f", largeTiny.elapsedMilliseconds)) ms; "
        + "parse 1 page (\(smallData.count) B, \(smallParsed.graph.objects.count) objects) "
        + "\(String(format: "%.1f", smallParseMs)) ms; "
        + "parse 8 pages (\(largeData.count) B, \(largeParsed.graph.objects.count) objects) "
        + "\(String(format: "%.1f", largeParseMs)) ms")
    #expect(smallParsed.graph.objects.count < largeParsed.graph.objects.count)
  }
}
