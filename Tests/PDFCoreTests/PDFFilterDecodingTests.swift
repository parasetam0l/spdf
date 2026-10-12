import Foundation
import Testing

@testable import PDFCore

/// P07-006..P07-012 evidence: ASCIIHexDecode, ASCII85Decode, RunLengthDecode,
/// LZWDecode with EarlyChange, and TIFF/PNG predictor reconstruction.
@Suite("Filter decoding")
struct PDFFilterDecodingTests {
  /// Extracted from an LZW-compressed TIFF produced by macOS ImageIO
  /// (`sips -s format tiff -s formatOptions lzw` on a synthetic 48x48 RGB
  /// bitmap, 2026-10-10; TIFF predictor 2, one 429-byte strip). ImageIO uses
  /// the same conventions as PDF LZW (MSB-first codes, EarlyChange=1). The
  /// strip crosses the 511-entry code-width transition (max table index 623)
  /// and was independently decoded by a Python reference on the same day.
  private static let imageIOLZWStripHex =
    "803042c8d068140f0583c1a110b85436130f864421d118a44e2d128c45633178" +
    "d476390e5f82d151e8dc9649278fc9a5328954b658bd0021e593395cd65d369a" +
    "4de751a5dbd50939a04e2853ba1d0688075cba90346a65169d47a6d1d6edf3f" +
    "546ad4fabd42b10e5ab50f759b056eb563a32cd9278b0d92c569b643962be3ad" +
    "b6d573b95655eb3395d6d77bba5f222ad541bef57dc260e58ab4e9b30d7ec66" +
    "169ea9491a7178eca64e10a74399b2d8dcde514a7c31e77459cbe28ce260d1e" +
    "5749aa03a84cc5dd4ec757394f96cb5b2d66e2489d2815f75b3e05cd36452a6" +
    "ff73c1a32647451e373791064b8bc9dcee3f5658951212fa9dbd5a4c3248ee7" +
    "5b9f25488388be1f45f11e03217a7c5ef84235f03ff77d69e8b768f3edf0f1a" +
    "25c41cbf700a6c439ae1b404fe3584299819c0f06a2e419821841d042d24096" +
    "c16c270ca0c3f956154350a2f83e94013c3f098f6ec44af1ad23c91410c5310" +
    "2c63b8fe0f45f038ea3a0371ac54be0e6348311d4609c8e22f02b203f6378a6" +
    "0948d1dac63689007c9720a6c3587a064a2f70d2190132bc989c8ce1380d2e4" +
    "a4928ca0e007313c231822004d12ea6c8080"

  @Test func lzwStripFromImageIODecodesWithTIFFPredictor() throws {
    let strip = try #require(Data(hexString: Self.imageIOLZWStripHex))
    let stream = PDFStream(
      dictionary: [
        PDFName("Filter"): .name(PDFName("LZWDecode")),
        PDFName("DecodeParms"): .dictionary([
          PDFName("Predictor"): .integer(2),
          PDFName("Colors"): .integer(3),
          PDFName("Columns"): .integer(48),
        ]),
      ], bytes: strip)
    let decoded = try PDFFilters.decoded(stream)
    var expected = Data()
    for y in 0..<48 {
      for x in 0..<48 {
        let row = 47 - y  // source bitmap rows were stored bottom-up
        expected.append(UInt8((x * 13 + row * 2 + 99) & 255))
        expected.append(UInt8((x * 5 + row * 11 + 17) & 255))
        expected.append(UInt8((x * 7 + row * 3) & 255))
      }
    }
    #expect(decoded == expected)
  }

  @Test func lzwSpecificationExampleAndClearCodesDecode() throws {
    // ISO 32000-1 7.4.4.2 example: "-----A---B" with codes 256 45 258 258
    // 65 259 66 257.
    let example = Self.packLZWCodes([256, 45, 258, 258, 65, 259, 66, 257], width: 9)
    let decoded = try PDFFilters.lzwDecode(example, parms: .null, limits: PDFLimits())
    #expect(decoded == Data([45, 45, 45, 45, 45, 65, 45, 45, 45, 66]))

    // A mid-stream Clear resets the table and code width.
    let reset = Self.packLZWCodes([256, 65, 66, 256, 67, 257], width: 9)
    #expect(try PDFFilters.lzwDecode(reset, parms: .null, limits: PDFLimits()) == Data("ABC".utf8))
  }

  @Test func lzwRoundTripsAcrossCodeWidthTransitionsAndEarlyChange() throws {
    var state: UInt64 = 0x5DEE_CE66_D1CE
    let payload = Data(
      (0..<6_000).map { _ -> UInt8 in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return UInt8(truncatingIfNeeded: state >> 33)
      })
    for earlyChange in [1, 0] {
      let encoded = Self.lzwEncode(payload, earlyChange: earlyChange)
      let parms: PDFValue = .dictionary([
        PDFName("EarlyChange"): .integer(Int64(earlyChange))
      ])
      let decoded = try PDFFilters.lzwDecode(encoded, parms: parms, limits: PDFLimits())
      #expect(decoded == payload)
    }
    let text = Data(String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 120).utf8)
    for earlyChange in [1, 0] {
      let encoded = Self.lzwEncode(text, earlyChange: earlyChange)
      let parms: PDFValue = .dictionary([
        PDFName("EarlyChange"): .integer(Int64(earlyChange))
      ])
      #expect(try PDFFilters.lzwDecode(encoded, parms: parms, limits: PDFLimits()) == text)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFFilters.lzwDecode(
        Data(), parms: .dictionary([PDFName("EarlyChange"): .integer(2)]), limits: PDFLimits())
    }
  }

  @Test func asciiHexHandlesWhitespaceOddDigitsAndTerminator() throws {
    #expect(
      try Self.decode(Data("48 65 6C 6C 6F>".utf8), filter: PDFName("ASCIIHexDecode"))
        == Data("Hello".utf8))
    #expect(try Self.decode(Data("7>".utf8), filter: PDFName("AHx")) == Data([0x70]))
    #expect(throws: PDFError.self) {
      _ = try Self.decode(Data("GG>".utf8), filter: PDFName("ASCIIHexDecode"))
    }
    #expect(throws: PDFError.self) {
      _ = try Self.decode(Data("41".utf8), filter: PDFName("ASCIIHexDecode"))
    }
    let long = Data(String(repeating: "41", count: 64).utf8) + Data(">".utf8)
    #expect(throws: PDFError.self) {
      _ = try Self.decode(long, filter: PDFName("ASCIIHexDecode"), limits: PDFLimits(decodedBytes: 32))
    }
  }

  @Test func ascii85HandlesFullPartialZAndTerminators() throws {
    #expect(
      try Self.decode(Data("87cURD_*#-6q/;2Bl%m&EcWB~>".utf8), filter: PDFName("ASCII85Decode"))
        == Data("Hello, PDF filters!".utf8))
    #expect(
      try Self.decode(
        Data("<~87cURD_*#-6q/;2Bl%m&EcWB~>".utf8), filter: PDFName("ASCII85Decode"))
        == Data("Hello, PDF filters!".utf8))
    #expect(
      try Self.decode(Data("zz~>".utf8), filter: PDFName("ASCII85Decode"))
        == Data(repeating: 0, count: 8))
    #expect(try Self.decode(Data("@:E^~>".utf8), filter: PDFName("A85")) == Data("abc".utf8))
    #expect(try Self.decode(Data("@:E_WAH~>".utf8), filter: PDFName("A85")) == Data("abcde".utf8))
    #expect(throws: PDFError.self) {
      _ = try Self.decode(Data("!!z~>".utf8), filter: PDFName("ASCII85Decode"))
    }
    #expect(throws: PDFError.self) {
      _ = try Self.decode(Data("v~>".utf8), filter: PDFName("ASCII85Decode"))
    }
    #expect(throws: PDFError.self) {
      _ = try Self.decode(Data("87cURD".utf8), filter: PDFName("ASCII85Decode"))
    }
    #expect(throws: PDFError.self) {
      _ = try Self.decode(Data("!~>".utf8), filter: PDFName("ASCII85Decode"))
    }
  }

  @Test func runLengthCopiesRepeatsAndRequiresEOD() throws {
    var encoded = Data([2, 65, 66, 67])
    encoded.append(contentsOf: [254, 68])
    encoded.append(128)
    #expect(
      try Self.decode(encoded, filter: PDFName("RunLengthDecode")) == Data("ABCDDD".utf8))
    #expect(
      try Self.decode(Data([129, 90, 128]), filter: PDFName("RL"))
        == Data(repeating: 90, count: 128))
    #expect(throws: PDFError.self) {
      _ = try Self.decode(Data([2, 65, 66]), filter: PDFName("RunLengthDecode"))
    }
    #expect(throws: PDFError.self) {
      _ = try Self.decode(Data([2, 65, 66, 67]), filter: PDFName("RunLengthDecode"))
    }
  }

  @Test func tiffPredictorReconstructsKnownRows() throws {
    let parms: PDFValue = .dictionary([
      PDFName("Predictor"): .integer(2), PDFName("Columns"): .integer(3),
    ])
    let decoded = try PDFFilters.applyPredictor(
      Data([10, 5, 7, 20, 4, 3]), parms: parms, limits: PDFLimits())
    #expect(decoded == Data([10, 15, 22, 20, 24, 27]))
  }

  @Test func pngPredictorReconstructsAllFiveFilters() throws {
    var rows = Data()
    rows.append(contentsOf: [0, 10, 20, 30])
    rows.append(contentsOf: [1, 5, 10, 15])
    rows.append(contentsOf: [2, 1, 2, 3])
    rows.append(contentsOf: [3, 9, 9, 9])
    rows.append(contentsOf: [4, 11, 11, 11])
    let parms: PDFValue = .dictionary([
      PDFName("Predictor"): .integer(15), PDFName("Colors"): .integer(1),
      PDFName("Columns"): .integer(3),
    ])
    let decoded = try PDFFilters.applyPredictor(rows, parms: parms, limits: PDFLimits())
    #expect(decoded == Data([10, 20, 30, 5, 15, 30, 6, 17, 33, 12, 23, 37, 23, 34, 48]))
  }

  @Test func predictorParametersAndLimitsFailExplicitly() throws {
    // A fixed predictor rejects rows with a different filter byte.
    let fixed: PDFValue = .dictionary([
      PDFName("Predictor"): .integer(12), PDFName("Columns"): .integer(3),
    ])
    #expect(throws: PDFError.self) {
      _ = try PDFFilters.applyPredictor(Data([1, 5, 10, 15]), parms: fixed, limits: PDFLimits())
    }
    let sub: PDFValue = .dictionary([
      PDFName("Predictor"): .integer(11), PDFName("Columns"): .integer(3),
    ])
    #expect(
      try PDFFilters.applyPredictor(Data([1, 5, 10, 15]), parms: sub, limits: PDFLimits())
        == Data([5, 15, 30]))
    // Columns is required and must stay within the decoded budget.
    #expect(throws: PDFError.self) {
      _ = try PDFFilters.applyPredictor(
        Data([0, 1, 2]),
        parms: .dictionary([PDFName("Predictor"): .integer(12)]), limits: PDFLimits())
    }
    #expect(throws: PDFError.self) {
      _ = try PDFFilters.applyPredictor(
        Data([0, 1, 2]),
        parms: .dictionary([
          PDFName("Predictor"): .integer(12), PDFName("Columns"): .integer(200_000_000),
        ]), limits: PDFLimits())
    }
    #expect(throws: PDFError.self) {
      _ = try PDFFilters.applyPredictor(
        Data([0, 1, 2]),
        parms: .dictionary([
          PDFName("Predictor"): .integer(12), PDFName("BitsPerComponent"): .integer(16),
          PDFName("Columns"): .integer(1),
        ]), limits: PDFLimits())
    }
  }

  @Test func chainedFiltersAndPredictorThroughFlate() throws {
    // Python-produced vector: base64.a85encode(zlib.compress(
    //   b"chained ASCII85 + Flate payload"), adobe=False) + "~>".
    let composite =
      "GaqFP8Bf:N9i5j<G4tR80NHJ#E6Cg(8Q@00XN\\d^9E>-bC'l3~>"
    let stream = PDFStream(
      dictionary: [
        PDFName("Filter"): .array([
          .name(PDFName("ASCII85Decode")), .name(PDFName("FlateDecode")),
        ])
      ], bytes: Data(composite.utf8))
    #expect(try PDFFilters.decoded(stream) == Data("chained ASCII85 + Flate payload".utf8))

    let rows = Data([2, 10, 20, 30])
    let predictorStream = PDFStream(
      dictionary: [
        PDFName("Filter"): .name(PDFName("FlateDecode")),
        PDFName("DecodeParms"): .dictionary([
          PDFName("Predictor"): .integer(12), PDFName("Columns"): .integer(3),
        ]),
      ], bytes: try PDFFilters.encodeFlate(rows))
    #expect(try PDFFilters.decoded(predictorStream) == Data([10, 20, 30]))
  }

  // MARK: - Helpers

  private static func decode(
    _ bytes: Data, filter: PDFName, limits: PDFLimits = PDFLimits()
  ) throws -> Data {
    try PDFFilters.decoded(
      PDFStream(dictionary: [PDFName("Filter"): .name(filter)], bytes: bytes), limits: limits)
  }

  private static func packLZWCodes(_ codes: [Int], width: Int) -> Data {
    var bits: [UInt8] = []
    for code in codes {
      for shift in stride(from: width - 1, through: 0, by: -1) {
        bits.append(UInt8((code >> shift) & 1))
      }
    }
    return packBits(bits)
  }

  private static func packBits(_ bits: [UInt8]) -> Data {
    var output = Data()
    var index = 0
    while index < bits.count {
      var byte: UInt8 = 0
      for offset in 0..<8 {
        byte = (byte << 1) | (index + offset < bits.count ? bits[index + offset] : 0)
      }
      output.append(byte)
      index += 8
    }
    return output
  }

  /// Test-only LZW encoder mirroring the PDF encoder convention: writes the
  /// code, adds the table entry, then widens one entry after the decoder's
  /// threshold so both sides stay aligned (validated against the ImageIO
  /// strip above).
  private static func lzwEncode(_ input: Data, earlyChange: Int) -> Data {
    var bits: [UInt8] = []
    func write(_ value: Int, _ width: Int) {
      for shift in stride(from: width - 1, through: 0, by: -1) {
        bits.append(UInt8((value >> shift) & 1))
      }
    }
    var table: [[UInt8]: Int] = [:]
    for value in 0..<256 { table[[UInt8(value)]] = value }
    var codeWidth = 9
    var nextCode = 258
    write(256, codeWidth)
    var current: [UInt8] = []
    for byte in input {
      var candidate = current
      candidate.append(byte)
      if table[candidate] != nil {
        current = candidate
        continue
      }
      if !current.isEmpty, let code = table[current] {
        write(code, codeWidth)
      }
      if nextCode < 4_096 {
        table[candidate] = nextCode
        nextCode += 1
        if codeWidth < 12, nextCode == (1 << codeWidth) - earlyChange + 1 {
          codeWidth += 1
        }
      }
      current = [byte]
    }
    if !current.isEmpty, let code = table[current] {
      write(code, codeWidth)
    }
    write(257, codeWidth)
    return packBits(bits)
  }
}

private extension Data {
  init?(hexString: String) {
    let clean = hexString.filter { !$0.isWhitespace }
    guard clean.count % 2 == 0 else { return nil }
    var bytes: [UInt8] = []
    var index = clean.startIndex
    while index < clean.endIndex {
      let next = clean.index(index, offsetBy: 2)
      guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    self = Data(bytes)
  }
}
