import Foundation
import PDFCore
import PDFFixtures
@testable import PDFEditing
import Testing

/// P38-001–P38-013: deterministic fuzz seeds and the adversarial input
/// families. Every mutant must either parse successfully or fail with an
/// explicit `PDFError` inside a bounded time — never hang, trap, or corrupt
/// state. Seeds are fixed constants so failures are reproducible.
@Suite("Parser fuzzing")
struct ParserFuzzTests {
  // MARK: - P38-001: deterministic seeds and limits

  static let seedLexical: UInt64 = 0x5EED_0001
  static let seedNesting: UInt64 = 0x5EED_0002
  static let seedXRef: UInt64 = 0x5EED_0003
  static let seedObjectStream: UInt64 = 0x5EED_0004
  static let seedStreams: UInt64 = 0x5EED_0005
  static let seedContent: UInt64 = 0x5EED_0006
  static let seedFonts: UInt64 = 0x5EED_0007
  static let seedImages: UInt64 = 0x5EED_0008
  static let seedAnnotations: UInt64 = 0x5EED_0009
  static let seedTags: UInt64 = 0x5EED_000A
  static let seedEncryption: UInt64 = 0x5EED_000B
  static let seedSignatures: UInt64 = 0x5EED_000C
  /// Resource budgets the fuzz runs enforce.
  static let perMutantMilliseconds = 500
  static let iterations = 120

  struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
    mutating func int(_ range: Range<Int>) -> Int {
      range.lowerBound + Int(next() % UInt64(max(range.count, 1)))
    }
    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
  }

  struct FuzzOutcome {
    var ran = 0
    var threw = 0
    var succeeded = 0
    var unexpected = 0
    var slowestMilliseconds = 0
    var errorKinds: [String: Int] = [:]

    var summary: String {
      "ran \(ran), succeeded \(succeeded), PDFError \(threw), unexpected \(unexpected), slowest \(slowestMilliseconds) ms, kinds \(errorKinds.sorted { $0.key < $1.key })"
    }
  }

  func fuzz(
    seed: UInt64, iterations: Int = iterations,
    mutate: (inout SplitMix64, Int) throws -> Data, exercise: (Data) throws -> Void
  ) throws -> FuzzOutcome {
    var rng = SplitMix64(seed: seed)
    var outcome = FuzzOutcome()
    for iteration in 0..<iterations {
      let data = try mutate(&rng, iteration)
      let start = ContinuousClock.now
      do {
        try exercise(data)
        outcome.succeeded += 1
      } catch let error as PDFError {
        outcome.threw += 1
        outcome.errorKinds[String(describing: error.kind), default: 0] += 1
      } catch {
        outcome.unexpected += 1
        outcome.errorKinds["unexpected: \(type(of: error))", default: 0] += 1
      }
      let elapsed = ContinuousClock.now - start
      let milliseconds =
        Int(elapsed.components.seconds * 1000)
        + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
      outcome.slowestMilliseconds = max(outcome.slowestMilliseconds, milliseconds)
      outcome.ran += 1
    }
    return outcome
  }

  func expectBounded(
    _ outcome: FuzzOutcome, family: String, sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(outcome.ran == Self.iterations, "\(family): \(outcome.summary)")
    #expect(outcome.unexpected == 0, "\(family): \(outcome.summary)")
    #expect(
      outcome.slowestMilliseconds < Self.perMutantMilliseconds,
      "\(family): \(outcome.summary)")
    print("[P38] \(family): \(outcome.summary)")
  }

  private func fixture(_ relative: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures")
      .appendingPathComponent(relative)
    return try Data(contentsOf: url)
  }

  private func mutateBytes(
    _ base: Data, rng: inout SplitMix64, iteration: Int
  ) -> Data {
    var data = base
    switch iteration % 4 {
    case 0:
      // Truncate at a random point.
      let length = max(1, rng.int(1..<max(base.count, 2)))
      data = Data(base.prefix(length))
    case 1:
      // Insert a structural delimiter or hostile byte.
      let hostile: [UInt8] = [0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x2F, 0x25, 0x00, 0xFF]
      let index = rng.int(0..<max(base.count, 1))
      data.insert(hostile[rng.int(0..<hostile.count)], at: index)
    case 2:
      // Replace a byte with a hostile one.
      if !data.isEmpty {
        let index = rng.int(0..<data.count)
        data[data.startIndex + index] = [0x00, 0xFF, 0x28, 0x5D][rng.int(0..<4)]
      }
    default:
      // Append junk or a duplicate end marker.
      data.append(contentsOf: rng.next() % 2 == 0 ? Array("%%EOF\n".utf8) : Array("junk".utf8))
    }
    return data
  }

  // MARK: - P38-002: lexical syntax

  @Test func lexicalSyntaxFuzzing() throws {
    let base = try PDFFixtures.onePage()
    let outcome = try fuzz(seed: Self.seedLexical) { rng, iteration in
      mutateBytes(base, rng: &rng, iteration: iteration)
    } exercise: { data in
      _ = try PDFParser.parse(data)
    }
    expectBounded(outcome, family: "lexical")
    // Truncation must fail explicitly, never silently succeed.
    #expect(outcome.threw > 0)
  }

  // MARK: - P38-003: object nesting and cycles

  /// Builds a valid PDF (catalog + empty page tree) whose catalog carries an
  /// array nested `depth` levels deep under /Deep.
  private func deepPDF(depth: Int) -> Data {
    let deep =
      String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth)
    var data = Data("%PDF-1.7\n".utf8)
    var offsets: [Int] = []
    offsets.append(data.count)
    data.append(Data("1 0 obj\n<< /Type /Catalog /Pages 2 0 R /Deep \(deep) >>\nendobj\n".utf8))
    offsets.append(data.count)
    data.append(
      Data("2 0 obj\n<< /Type /Pages /Count 0 /Kids [] >>\nendobj\n".utf8))
    let xrefOffset = data.count
    data.append(Data("xref\n0 3\n0000000000 65535 f \n".utf8))
    for offset in offsets {
      data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
    }
    data.append(
      Data("trailer\n<< /Size 3 /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
    return data
  }

  @Test func nestingDepthIsBoundedAtParseTime() throws {
    // Hostile files cannot deliver unbounded nesting: the parser's limit is
    // the defense (the profile's default is 64, capped at 256).
    let limits = PDFLimits()
    #expect(limits.nesting == 64)
    let outcome = try fuzz(seed: Self.seedNesting) { rng, iteration in
      self.deepPDF(depth: 1 + rng.int(0..<256))
    } exercise: { data in
      _ = try PDFParser.parse(data)
    }
    expectBounded(outcome, family: "nesting depth")
    // Beyond the limit the failure is explicit and classified.
    #expect(outcome.threw > 0)
    #expect(outcome.errorKinds["limitExceeded", default: 0] > 0)
    #expect(outcome.errorKinds["malformed", default: 0] == 0)
    // The writer enforces the same bound for programmatically built values.
    var deep: PDFValue = .integer(1)
    for _ in 0..<200 { deep = .array([deep]) }
    #expect(throws: PDFError.self) {
      _ = try PDFWriter.serializedValue(deep)
    }
  }

  @Test func cyclicReferenceGraphsStayBounded() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let outcome = try fuzz(seed: Self.seedNesting &+ 1) { rng, iteration in
      var graph = parsed.graph
      switch iteration % 3 {
      case 0:
        graph.objects[PDFObjectID(901)] = .reference(PDFObjectID(901))
      case 1:
        graph.objects[PDFObjectID(902)] = .reference(PDFObjectID(903))
        graph.objects[PDFObjectID(903)] = .reference(PDFObjectID(902))
      default:
        graph.objects[PDFObjectID(905)] = .dictionary([
          PDFName("Self"): .reference(PDFObjectID(905)),
          PDFName("Deep"): .array([.array([.array([.reference(PDFObjectID(905))])])]),
        ])
      }
      return try PDFWriter.write(graph)
    } exercise: { data in
      let reparsed = try PDFParser.parse(data)
      try reparsed.graph.validate()
    }
    expectBounded(outcome, family: "cycles")
    // Cycles are legal PDF and pass validation without hanging.
    #expect(outcome.succeeded > 0)
    #expect(outcome.threw == 0)
    // A dangling reference is refused explicitly (never written out).
    var dangling = parsed.graph
    dangling.objects[PDFObjectID(906)] = .reference(PDFObjectID(999_999))
    #expect(throws: PDFError.self) {
      _ = try PDFWriter.write(dangling)
    }
  }

  // MARK: - P38-004: cross-reference offsets, sizes, ranges, revisions

  @Test func crossReferenceFuzzing() throws {
    let base = try PDFFixtures.onePage()
    let outcome = try fuzz(seed: Self.seedXRef) { rng, iteration in
      var data = base
      let text = String(decoding: data, as: UTF8.self)
      switch iteration % 4 {
      case 0:
        // Corrupt the startxref offset digits.
        if let range = text.range(of: "startxref", options: .backwards) {
          let offset = text.distance(from: text.startIndex, to: range.upperBound)
          let digits = "\(rng.int(0..<999_999))"
          var bytes = data
          let start = bytes.startIndex + offset + 1
          for (index, byte) in digits.utf8.enumerated() {
            let position = start + index
            if position < bytes.endIndex { bytes[position] = byte }
          }
          data = bytes
        }
      case 1:
        // Corrupt an xref entry count.
        if let range = text.range(of: "\nxref\n") {
          let offset = text.distance(from: text.startIndex, to: range.upperBound)
          var bytes = data
          let digits = "\(rng.int(0..<9_999))"
          let start = bytes.startIndex + offset
          for (index, byte) in digits.utf8.enumerated() {
            let position = start + index
            if position < bytes.endIndex { bytes[position] = byte }
          }
          data = bytes
        }
      case 2:
        // Append a bogus revision with its own trailer.
        data.append(Data("\n\(rng.int(0..<9_999)) 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF\n".utf8))
      default:
        // Corrupt entry offsets inside the table.
        if let range = text.range(of: "xref") {
          let offset = text.distance(from: text.startIndex, to: range.upperBound)
          var bytes = data
          for _ in 0..<rng.int(1..<8) {
            let position = bytes.startIndex + offset + rng.int(0..<min(120, max(bytes.count - offset, 1)))
            if position < bytes.endIndex { bytes[position] = rng.byte() }
          }
          data = bytes
        }
      }
      return data
    } exercise: { data in
      _ = try PDFParser.parse(data)
    }
    expectBounded(outcome, family: "xref/revisions")
  }

  // MARK: - P38-005: object streams

  @Test func objectStreamFuzzing() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let compressed = try PDFWriter.writeCompressed(parsed.graph)
    let outcome = try fuzz(seed: Self.seedObjectStream) { rng, iteration in
      var data = compressed
      let text = String(decoding: compressed, as: UTF8.self)
      switch iteration % 3 {
      case 0:
        if let range = text.range(of: "/N ") {
          let offset = text.distance(from: text.startIndex, to: range.upperBound)
          var bytes = data
          let digits = "\(rng.int(0..<9_999))"
          let start = bytes.startIndex + offset
          for (index, byte) in digits.utf8.enumerated() {
            let position = start + index
            if position < bytes.endIndex { bytes[position] = byte }
          }
          data = bytes
        }
      case 1:
        if let range = text.range(of: "/First ") {
          let offset = text.distance(from: text.startIndex, to: range.upperBound)
          var bytes = data
          let digits = "\(rng.int(0..<99_999))"
          let start = bytes.startIndex + offset
          for (index, byte) in digits.utf8.enumerated() {
            let position = start + index
            if position < bytes.endIndex { bytes[position] = byte }
          }
          data = bytes
        }
      default:
        // Corrupt stream bytes near the end (object-stream payload region).
        if data.count > 40 {
          let index = rng.int(0..<(data.count - 20))
          data[data.startIndex + index] = rng.byte()
        }
      }
      return data
    } exercise: { data in
      _ = try PDFParser.parse(data)
    }
    expectBounded(outcome, family: "object streams")
  }

  // MARK: - P38-006: stream lengths, filter chains, expansion ratios

  @Test func streamLengthAndFilterFuzzing() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let pageID = parsed.pageIDs[0]
    let outcome = try fuzz(seed: Self.seedStreams) { rng, iteration in
      var graph = parsed.graph
      let payload = Data((0..<64).map { _ in rng.byte() })
      var dictionary: [PDFName: PDFValue] = [:]
      switch iteration % 5 {
      case 0:
        dictionary[PDFName("Length")] = .integer(Int64(rng.int(0..<100_000)))
      case 1:
        dictionary[PDFName("Filter")] = .array([
          .name(PDFName("FlateDecode")), .name(PDFName("FlateDecode")),
        ])
      case 2:
        dictionary[PDFName("Filter")] = .name(PDFName("NoSuchFilter"))
      case 3:
        dictionary[PDFName("Filter")] = .name(PDFName("ASCII85Decode"))
        dictionary[PDFName("DecodeParms")] = .dictionary([
          PDFName("Predictor"): .integer(Int64(rng.int(-10..<10_000))),
          PDFName("Columns"): .integer(Int64(rng.int(-10..<100_000))),
        ])
      default:
        // A highly compressible payload: one mebibyte of zeros.
        dictionary[PDFName("Filter")] = .name(PDFName("FlateDecode"))
        graph.objects[PDFObjectID(750)] = .stream(
          PDFStream(
            dictionary: dictionary,
            bytes: try PDFFilters.encodeFlate(Data(repeating: 0, count: 1_048_576))))
        return try PDFWriter.write(graph)
      }
      graph.objects[PDFObjectID(750)] = .stream(
        PDFStream(dictionary: dictionary, bytes: payload))
      // Also corrupt the page's own content stream length.
      if case .stream(var content)? = graph.objects[PDFObjectID(5)], iteration % 3 == 0 {
        content.dictionary[PDFName("Length")] = .integer(Int64(rng.int(0..<100_000)))
        graph.objects[PDFObjectID(5)] = .stream(content)
      }
      return try PDFWriter.write(graph)
    } exercise: { data in
      let reparsed = try PDFParser.parse(data)
      if case .stream(let stream)? = reparsed.graph.objects[PDFObjectID(750)] {
        _ = try? PDFFilters.decoded(stream)
      }
      _ = try? PageContent.load(pageID: pageID, in: reparsed.graph)
    }
    expectBounded(outcome, family: "stream lengths/filters")
    // The bomb must decode within the configured bound (or fail explicitly).
    let bomb = try PDFFilters.encodeFlate(Data(repeating: 0, count: 1_048_576))
    let limits = PDFLimits()
    do {
      let decoded = try PDFFilters.decoded(
        PDFStream(dictionary: [PDFName("Filter"): .name(PDFName("FlateDecode"))], bytes: bomb),
        limits: limits)
      #expect(decoded.count == 1_048_576)
    } catch let error as PDFError {
      #expect(error.kind == .limitExceeded)
    }
  }

  // MARK: - P38-007: content operands, graphics stacks, nested forms

  @Test func contentOperandFuzzing() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let pageID = parsed.pageIDs[0]
    let outcome = try fuzz(seed: Self.seedContent) { rng, iteration in
      var graph = parsed.graph
      var content = Data("BT /F1 12 Tf 72 700 Td (Hello) Tj ET\n".utf8)
      switch iteration % 5 {
      case 0:
        content.append(Data(String(repeating: "q ", count: 2_000).utf8))
      case 1:
        content.append(Data("BT /F1 12 Tf 1e999 1e-999 Td (\\u{FFFD}) Tj\n".utf8))
      case 2:
        content.append(Data("q 1 0 0 1 0 0 cm /X1 Do Q\n".utf8))
        graph.objects[PDFObjectID(700)] = .stream(
          PDFStream(
            dictionary: [
              PDFName("Type"): .name(PDFName("XObject")),
              PDFName("Subtype"): .name(PDFName("Form")),
              PDFName("BBox"): .array([
                .integer(0), .integer(0), .integer(100), .integer(100),
              ]),
              PDFName("Resources"): .dictionary([
                PDFName("XObject"): .dictionary([PDFName("X1"): .reference(PDFObjectID(700))])
              ]),
            ], bytes: Data("q /X1 Do Q\n".utf8)))
        if case .dictionary(var page)? = graph.objects[pageID] {
          var resources: [PDFName: PDFValue] = [:]
          if case .dictionary(let existing)? = page[PDFName("Resources")] { resources = existing }
          resources[PDFName("XObject")] = .dictionary([PDFName("X1"): .reference(PDFObjectID(700))])
          page[PDFName("Resources")] = .dictionary(resources)
          graph.objects[pageID] = .dictionary(page)
        }
      case 3:
        for _ in 0..<rng.int(1..<64) {
          content.append(rng.byte())
        }
      default:
        content.append(Data("1 0 0 1 \(rng.int(-999_999..<999_999)) 0 cm\n".utf8))
      }
      graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: content))
      return try PDFWriter.write(graph)
    } exercise: { data in
      let reparsed = try PDFParser.parse(data)
      let content = try PageContent.load(pageID: reparsed.pageIDs[0], in: reparsed.graph)
      _ = StructureTaggingAssistant.markedRanges(in: content)
      _ = try? PageTextLayout.build(pageID: reparsed.pageIDs[0], in: reparsed.graph)
    }
    expectBounded(outcome, family: "content operands")
  }

  // MARK: - P38-008: font tables, CMaps, Unicode mappings

  @Test func fontAndCMapFuzzing() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let pageID = parsed.pageIDs[0]
    let outcome = try fuzz(seed: Self.seedFonts) { rng, iteration in
      var graph = parsed.graph
      var font: [PDFName: PDFValue] = [
        PDFName("Type"): .name(PDFName("Font")),
        PDFName("Subtype"): .name(PDFName("Type1")),
        PDFName("BaseFont"): .name(PDFName("Helvetica")),
        PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
      ]
      switch iteration % 4 {
      case 0:
        font[PDFName("Widths")] = .array(
          (0..<rng.int(0..<4_000)).map { _ in .integer(Int64(rng.int(-10_000..<10_000))) })
        font[PDFName("FirstChar")] = .integer(Int64(rng.int(-100..<300)))
      case 1:
        font[PDFName("Encoding")] = .dictionary([
          PDFName("Differences"): .array(
            (0..<rng.int(0..<500)).map { _ in
              rng.next() % 2 == 0 ? .integer(Int64(rng.int(-50..<300))) : .name(PDFName("Bad"))
            })
        ])
      case 2:
        font[PDFName("ToUnicode")] = .reference(PDFObjectID(710))
        let cMap = "beginbfrange\n<\(String(format: "%04X", rng.int(0..<65_536)))> <FFFF> <0000>\nendbfrange\n"
        graph.objects[PDFObjectID(710)] = .stream(PDFStream(bytes: Data(cMap.utf8)))
      default:
        font[PDFName("Subtype")] = .name(PDFName("Type0"))
        font[PDFName("DescendantFonts")] = .array([.reference(PDFObjectID(711))])
        graph.objects[PDFObjectID(711)] = .dictionary([
          PDFName("Subtype"): .name(PDFName("CIDFontType2")),
          PDFName("BaseFont"): .name(PDFName("Bad")),
          PDFName("W"): .array((0..<rng.int(0..<200)).map { _ in .integer(Int64(rng.int(-999..<999))) }),
        ])
      }
      graph.objects[PDFObjectID(3)] = .dictionary(font)
      return try PDFWriter.write(graph)
    } exercise: { data in
      let reparsed = try PDFParser.parse(data)
      _ = try? PageTextLayout.build(pageID: reparsed.pageIDs[0], in: reparsed.graph)
      _ = PDFFontInventory.fonts(in: reparsed.graph, pageIDs: reparsed.pageIDs)
      if case .dictionary(let page)? = reparsed.graph.objects[reparsed.pageIDs[0]] {
        _ = try? SimpleFont.resolve(resource: PDFName("F1"), page: page, in: reparsed.graph)
      }
    }
    expectBounded(outcome, family: "fonts/CMaps")
  }

  // MARK: - P38-009: image dimensions, masks, predictors

  @Test func imageFuzzing() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let pageID = parsed.pageIDs[0]
    let outcome = try fuzz(seed: Self.seedImages) { rng, iteration in
      var graph = parsed.graph
      var dictionary: [PDFName: PDFValue] = [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Image")),
      ]
      switch iteration % 5 {
      case 0:
        dictionary[PDFName("Width")] = .integer(Int64(rng.int(1..<1_000_000_000)))
        dictionary[PDFName("Height")] = .integer(Int64(rng.int(1..<1_000_000_000)))
      case 1:
        dictionary[PDFName("BitsPerComponent")] = .integer(Int64(rng.int(-2..<40)))
      case 2:
        dictionary[PDFName("Filter")] = .name(PDFName("FlateDecode"))
        dictionary[PDFName("DecodeParms")] = .dictionary([
          PDFName("Predictor"): .integer(Int64(rng.int(-5..<30_000))),
          PDFName("Columns"): .integer(Int64(rng.int(-5..<100_000))),
          PDFName("Colors"): .integer(Int64(rng.int(-5..<100))),
        ])
      case 3:
        dictionary[PDFName("SMask")] = .reference(PDFObjectID(720))
      default:
        dictionary[PDFName("Mask")] = .array([
          .integer(0), .integer(0), .integer(1), .integer(1),
        ])
      }
      dictionary[PDFName("Width")] = dictionary[PDFName("Width")] ?? .integer(4)
      dictionary[PDFName("Height")] = dictionary[PDFName("Height")] ?? .integer(4)
      dictionary[PDFName("ColorSpace")] = .name(PDFName("DeviceRGB"))
      dictionary[PDFName("BitsPerComponent")] =
        dictionary[PDFName("BitsPerComponent")] ?? .integer(8)
      graph.objects[PDFObjectID(720)] = .stream(
        PDFStream(
          dictionary: [
            PDFName("Type"): .name(PDFName("XObject")),
            PDFName("Subtype"): .name(PDFName("Image")),
            PDFName("Width"): .integer(4), PDFName("Height"): .integer(4),
            PDFName("ColorSpace"): .name(PDFName("DeviceGray")),
            PDFName("BitsPerComponent"): .integer(8),
            PDFName("SMask"): .reference(PDFObjectID(720)),
          ], bytes: Data(repeating: 0, count: 16)))
      graph.objects[PDFObjectID(721)] = .stream(
        PDFStream(dictionary: dictionary, bytes: Data((0..<48).map { _ in rng.byte() })))
      if case .dictionary(var page)? = graph.objects[pageID] {
        var resources: [PDFName: PDFValue] = [:]
        if case .dictionary(let existing)? = page[PDFName("Resources")] { resources = existing }
        resources[PDFName("XObject")] = .dictionary([PDFName("Im1"): .reference(PDFObjectID(721))])
        page[PDFName("Resources")] = .dictionary(resources)
        graph.objects[pageID] = .dictionary(page)
      }
      if case .stream(var content)? = graph.objects[PDFObjectID(5)] {
        content.bytes.append(Data("q 10 0 0 10 0 0 cm /Im1 Do Q\n".utf8))
        graph.objects[PDFObjectID(5)] = .stream(content)
      }
      return try PDFWriter.write(graph)
    } exercise: { data in
      let reparsed = try PDFParser.parse(data)
      let images = try PDFImageInventory.images(in: reparsed.graph, pageIDs: reparsed.pageIDs)
      for image in images {
        guard let objectID = image.objectID,
          case .stream(let stream)? = reparsed.graph.objects[objectID]
        else { continue }
        _ = try? PDFFilters.decoded(stream)
      }
    }
    expectBounded(outcome, family: "images")
  }

  // MARK: - P38-010: annotation and form relationships

  @Test func annotationAndFormFuzzing() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let pageID = parsed.pageIDs[0]
    let outcome = try fuzz(seed: Self.seedAnnotations) { rng, iteration in
      var graph = parsed.graph
      switch iteration % 4 {
      case 0:
        graph.objects[PDFObjectID(730)] = .dictionary([
          PDFName("Type"): .name(PDFName("Annot")),
          PDFName("Subtype"): .name(PDFName("Widget")),
          PDFName("Rect"): .array([
            .integer(0), .integer(0), .integer(10), .integer(10),
          ]),
          PDFName("Parent"): .reference(PDFObjectID(731)),
        ])
        graph.objects[PDFObjectID(731)] = .dictionary([
          PDFName("Type"): .name(PDFName("Annot")),
          PDFName("Subtype"): .name(PDFName("Widget")),
          PDFName("Rect"): .array([
            .integer(0), .integer(0), .integer(10), .integer(10),
          ]),
          PDFName("Parent"): .reference(PDFObjectID(730)),
        ])
      case 1:
        graph.objects[PDFObjectID(732)] = .dictionary([
          PDFName("Type"): .name(PDFName("Annot")),
          PDFName("Subtype"): .name(PDFName("Widget")),
          PDFName("Rect"): .array(
            (0..<rng.int(0..<40)).map { _ in .integer(Int64(rng.int(-9_999..<9_999))) }),
          PDFName("Kids"): .array([.reference(PDFObjectID(732))]),
        ])
      default:
        for id in 730..<740 where graph.objects[PDFObjectID(id)] == nil {
          graph.objects[PDFObjectID(id)] = .dictionary([
            PDFName("Type"): .name(PDFName("Annot")),
            PDFName("Subtype"): .name(PDFName("Widget")),
            PDFName("Rect"): .array([
              .integer(0), .integer(0), .integer(10), .integer(10),
            ]),
          ])
        }
        graph.objects[PDFObjectID(733)] = .dictionary([
          PDFName("Fields"): .array(
            (0..<rng.int(0..<200)).map { _ in .reference(PDFObjectID(rng.int(730..<740))) }),
          PDFName("CO"): .array(
            (0..<rng.int(0..<100)).map { _ in .reference(PDFObjectID(rng.int(730..<740))) }),
        ])
      }
      if case .dictionary(var page)? = graph.objects[pageID] {
        page[PDFName("Annots")] = .array([
          .reference(PDFObjectID(730)), .reference(PDFObjectID(732)), .reference(PDFObjectID(733)),
        ])
        graph.objects[pageID] = .dictionary(page)
      }
      for id in 730..<740 where graph.objects[PDFObjectID(id)] == nil {
        graph.objects[PDFObjectID(id)] = .dictionary([
          PDFName("Type"): .name(PDFName("Annot")),
          PDFName("Subtype"): .name(PDFName("Widget")),
          PDFName("Rect"): .array([
            .integer(0), .integer(0), .integer(10), .integer(10),
          ]),
        ])
      }
      if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
        case .dictionary(var catalog)? = graph.objects[catalogID]
      {
        catalog[PDFName("AcroForm")] = .reference(PDFObjectID(733))
        graph.objects[catalogID] = .dictionary(catalog)
      }
      return try PDFWriter.write(graph)
    } exercise: { data in
      let reparsed = try PDFParser.parse(data)
      _ = try? FormInventory.fields(in: reparsed.graph, pageIDs: reparsed.pageIDs)
      for page in reparsed.pageIDs {
        _ = try? AnnotationInventory.annotations(in: reparsed.graph, pageID: page)
      }
    }
    expectBounded(outcome, family: "annotations/forms")
  }

  // MARK: - P38-011: tag trees, parent trees, destinations

  @Test func tagAndDestinationFuzzing() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let pageID = parsed.pageIDs[0]
    let outcome = try fuzz(seed: Self.seedTags) { rng, iteration in
      var graph = parsed.graph
      switch iteration % 4 {
      case 0:
        // A parent tree that points at itself.
        graph.objects[PDFObjectID(740)] = .dictionary([
          PDFName("Nums"): .array([.integer(0), .reference(PDFObjectID(740))])
        ])
      case 1:
        // Structure elements whose kid is another (cyclic) element.
        graph.objects[PDFObjectID(740)] = .dictionary([
          PDFName("Type"): .name(PDFName("StructElem")),
          PDFName("S"): .name(PDFName("Sect")),
          PDFName("K"): .array([.reference(PDFObjectID(741))]),
        ])
        graph.objects[PDFObjectID(741)] = .dictionary([
          PDFName("Type"): .name(PDFName("StructElem")),
          PDFName("S"): .name(PDFName("P")),
          PDFName("K"): .reference(PDFObjectID(740)),
        ])
      case 2:
        // A link with a huge destination array.
        graph.objects[PDFObjectID(742)] = .dictionary([
          PDFName("Type"): .name(PDFName("Annot")),
          PDFName("Subtype"): .name(PDFName("Link")),
          PDFName("Rect"): .array([
            .integer(0), .integer(0), .integer(10), .integer(10),
          ]),
          PDFName("Dest"): .array(
            (0..<rng.int(1..<500)).map { _ in .integer(Int64(rng.int(-999..<999))) }),
        ])
      default:
        graph.objects[PDFObjectID(743)] = .dictionary([
          PDFName("Type"): .name(PDFName("StructTreeRoot")),
          PDFName("ParentTree"): .reference(PDFObjectID(744)),
          PDFName("K"): .array([.reference(PDFObjectID(743))]),
        ])
        graph.objects[PDFObjectID(744)] = .dictionary([
          PDFName("Kids"): .array([.reference(PDFObjectID(744))])
        ])
      }
      if graph.objects[PDFObjectID(743)] == nil {
        graph.objects[PDFObjectID(743)] = .dictionary([
          PDFName("Type"): .name(PDFName("StructTreeRoot"))
        ])
      }
      if graph.objects[PDFObjectID(742)] == nil {
        graph.objects[PDFObjectID(742)] = .dictionary([
          PDFName("Type"): .name(PDFName("Annot")),
          PDFName("Subtype"): .name(PDFName("Link")),
          PDFName("Rect"): .array([
            .integer(0), .integer(0), .integer(10), .integer(10),
          ]),
        ])
      }
      if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
        case .dictionary(var catalog)? = graph.objects[catalogID]
      {
        catalog[PDFName("StructTreeRoot")] = .reference(PDFObjectID(743))
        graph.objects[catalogID] = .dictionary(catalog)
      }
      if case .dictionary(var page)? = graph.objects[pageID] {
        page[PDFName("Annots")] = .array([.reference(PDFObjectID(742))])
        graph.objects[pageID] = .dictionary(page)
      }
      return try PDFWriter.write(graph)
    } exercise: { data in
      let reparsed = try PDFParser.parse(data)
      _ = try? PDFStructureInspector.inspect(in: reparsed.graph, pageIDs: reparsed.pageIDs)
      _ = PDFLinkInventory.links(in: reparsed.graph, pageIDs: reparsed.pageIDs)
    }
    expectBounded(outcome, family: "tags/destinations")

    // A cyclic structure tree is reported as a cyclic reference and never
    // recursed into (P38-011).
    var cyclic = parsed.graph
    cyclic.objects[PDFObjectID(743)] = .dictionary([
      PDFName("Type"): .name(PDFName("StructTreeRoot")),
      PDFName("K"): .array([.reference(PDFObjectID(743))]),
    ])
    if case .reference(let catalogID)? = cyclic.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = cyclic.objects[catalogID]
    {
      catalog[PDFName("StructTreeRoot")] = .reference(PDFObjectID(743))
      cyclic.objects[catalogID] = .dictionary(catalog)
    }
    let inventory = try PDFStructureInspector.inspect(in: cyclic, pageIDs: parsed.pageIDs)
    #expect(inventory.issues.contains { $0.kind == .cyclicReference })
  }

  // MARK: - P38-012: encrypted dictionaries (no real credentials)

  @Test func encryptedDictionaryFuzzing() throws {
    let base = try fixture("Encrypted/aes-256-r6.pdf")
    let outcome = try fuzz(seed: Self.seedEncryption) { rng, iteration in
      var data = base
      let text = String(decoding: data, as: UTF8.self)
      switch iteration % 4 {
      case 0:
        if let range = text.range(of: "/Encrypt") {
          let offset = text.distance(from: text.startIndex, to: range.upperBound)
          var bytes = data
          for _ in 0..<rng.int(1..<32) {
            let position = bytes.startIndex + offset + rng.int(0..<200)
            if position < bytes.endIndex { bytes[position] = rng.byte() }
          }
          data = bytes
        }
      case 1:
        data = Data(base.prefix(max(1, rng.int(1..<base.count))))
      case 2:
        // Replace the /V and /R values with extreme ones.
        if let range = text.range(of: "/V ") {
          let offset = text.distance(from: text.startIndex, to: range.upperBound)
          var bytes = data
          let replacement = "\(rng.int(0..<99))"
          let start = bytes.startIndex + offset
          for (index, byte) in replacement.utf8.enumerated() {
            let position = start + index
            if position < bytes.endIndex { bytes[position] = byte }
          }
          data = bytes
        }
      default:
        // Corrupt the /O and /U strings.
        if let range = text.range(of: "/O ") {
          let offset = text.distance(from: text.startIndex, to: range.upperBound)
          var bytes = data
          for _ in 0..<rng.int(1..<24) {
            let position = bytes.startIndex + offset + rng.int(0..<120)
            if position < bytes.endIndex { bytes[position] = rng.byte() }
          }
          data = bytes
        }
      }
      return data
    } exercise: { data in
      // The synthetic fixture password is a test constant, not a credential.
      _ = try PDFParser.parse(data, password: "abc")
    }
    expectBounded(outcome, family: "encryption")
    #expect(outcome.threw > 0)
  }

  // MARK: - P38-013: signature byte ranges and ASN.1

  @Test func signatureFuzzing() throws {
    let base = try fixture("Signed/signed-one-page.pdf")
    let outcome = try fuzz(seed: Self.seedSignatures) { rng, iteration in
      var data = base
      let text = String(decoding: data, as: UTF8.self)
      switch iteration % 3 {
      case 0:
        if let range = text.range(of: "/ByteRange") {
          let offset = text.distance(from: text.startIndex, to: range.upperBound)
          var bytes = data
          for _ in 0..<rng.int(1..<40) {
            let position = bytes.startIndex + offset + rng.int(0..<80)
            if position < bytes.endIndex { bytes[position] = rng.byte() }
          }
          data = bytes
        }
      case 1:
        // Truncate the signed bytes (breaks the byte range coverage).
        data = Data(base.prefix(max(1, rng.int(1..<base.count))))
      default:
        // Corrupt the /Contents hex payload.
        if let range = text.range(of: "/Contents") {
          let offset = text.distance(from: text.startIndex, to: range.upperBound)
          var bytes = data
          for _ in 0..<rng.int(1..<32) {
            let position = bytes.startIndex + offset + rng.int(0..<200)
            if position < bytes.endIndex { bytes[position] = rng.byte() }
          }
          data = bytes
        }
      }
      return data
    } exercise: { data in
      let reparsed = try PDFParser.parse(data)
      _ = try PDFSignatureInventory.signatures(in: reparsed.graph)
    }
    expectBounded(outcome, family: "signatures")
  }
}
