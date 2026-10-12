import Compression
import Foundation
import Testing
import zlib

@testable import PDFCore

/// P07 evidence: PDF FlateDecode framing (RFC 1950), checksum handling, and
/// bounded decoding against an independent producer and independent decoder.
@Suite("Stream decoding")
struct PDFStreamDecodingTests {
  /// Produced by CPython `zlib.compress(b"sPDF FlateDecode independent vector")`
  /// (zlib 1.2.x on macOS). Hardcoded so our decoder is checked against an
  /// encoder outside the app toolchain.
  private static let pythonVector = Data([
    0x78, 0x9C, 0x2B, 0x0E, 0x70, 0x71, 0x53, 0x70, 0xCB, 0x49, 0x2C, 0x49, 0x75, 0x49, 0x4D,
    0xCE, 0x4F, 0x49, 0x55, 0xC8, 0xCC, 0x4B, 0x49, 0x2D, 0x48, 0x05, 0x12, 0x79, 0x25, 0x0A,
    0x65, 0xA9, 0xC9, 0x25, 0xF9, 0x45, 0x00, 0xDF, 0x42, 0x0C, 0xFF,
  ])
  private static let pythonVectorPlain = Data("sPDF FlateDecode independent vector".utf8)
  private static let flate = PDFName("FlateDecode")

  @Test func decodesBytesFromAnIndependentZlibProducer() throws {
    let stream = PDFStream(dictionary: [PDFName("Filter"): .name(Self.flate)], bytes: Self.pythonVector)
    #expect(try PDFFilters.decoded(stream) == Self.pythonVectorPlain)
  }

  @Test func outputHasValidZlibFramingChecksumAndRawDeflateBody() throws {
    let payload = Data((0..<1_024).map { UInt8($0 % 251) })
    let encoded = try PDFFilters.encodeFlate(payload)
    let cmf = Int(encoded[encoded.startIndex])
    let flg = Int(encoded[encoded.startIndex + 1])
    #expect(cmf & 0x0F == 8, "CM must be DEFLATE")
    #expect((cmf * 256 + flg) % 31 == 0, "FCHECK must validate")
    let checksum = Self.adler32(payload)
    let tail = Array(encoded.suffix(4))
    #expect(
      tail == [
        UInt8((checksum >> 24) & 0xFF), UInt8((checksum >> 16) & 0xFF),
        UInt8((checksum >> 8) & 0xFF), UInt8(checksum & 0xFF),
      ], "Adler-32 must match an independent implementation")
    // Apple's Compression decoder is independent of zlib; it reads the raw
    // DEFLATE body once the zlib wrapper and checksum are removed.
    let body = Data(encoded.dropFirst(2).dropLast(4))
    #expect(Self.appleRawInflate(body, expectedSize: payload.count) == payload)
    #expect(
      try PDFFilters.decoded(PDFStream(dictionary: [PDFName("Filter"): .name(Self.flate)], bytes: encoded))
        == payload)
  }

  @Test func filterNamesAndDecodeParmsAlign() throws {
    #expect(try PDFFilters.filterNames(in: [:]).isEmpty)
    #expect(try PDFFilters.filterNames(in: [PDFName("Filter"): .null]).isEmpty)
    #expect(
      try PDFFilters.filterNames(in: [PDFName("Filter"): .name(Self.flate)]) == [Self.flate])
    #expect(
      try PDFFilters.filterNames(in: [
        PDFName("Filter"): .array([.name(Self.flate), .name(PDFName("Fl"))])
      ]).count == 2)
    #expect(throws: PDFError.self) {
      _ = try PDFFilters.filterNames(in: [PDFName("Filter"): .array([.integer(1)])])
    }
    #expect(
      try PDFFilters.decodeParms(
        in: [
          PDFName("Filter"): .array([.name(Self.flate)]), PDFName("DecodeParms"): .array([.null]),
        ], filterCount: 1).count == 1)
    #expect(throws: PDFError.self) {
      _ = try PDFFilters.decodeParms(in: [PDFName("DecodeParms"): .array([.null])], filterCount: 2)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFFilters.decodeParms(
        in: [PDFName("DecodeParms"): .array([.integer(3)])], filterCount: 1)
    }
  }

  @Test func chainedFlateFiltersDecodeInOrder() throws {
    let payload = Data("chained filter payload".utf8)
    let once = try PDFFilters.encodeFlate(payload)
    let twice = try PDFFilters.encodeFlate(once)
    let stream = PDFStream(
      dictionary: [PDFName("Filter"): .array([.name(Self.flate), .name(PDFName("Fl"))])],
      bytes: twice)
    #expect(try PDFFilters.decoded(stream) == payload)
  }

  @Test func unsupportedFiltersAndPredictorsFailExplicitly() throws {
    let unsupported = PDFStream(
      dictionary: [PDFName("Filter"): .name(PDFName("DCTDecode"))], bytes: Data("data".utf8))
    do {
      _ = try PDFFilters.decoded(unsupported)
      Issue.record("Unsupported filter was decoded")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
    }
    let deepSamples = PDFStream(
      dictionary: [
        PDFName("Filter"): .name(Self.flate),
        PDFName("DecodeParms"): .dictionary([
          PDFName("Predictor"): .integer(12), PDFName("BitsPerComponent"): .integer(16),
          PDFName("Columns"): .integer(1),
        ]),
      ], bytes: try PDFFilters.encodeFlate(Data([0, 1, 2])))
    do {
      _ = try PDFFilters.decoded(deepSamples)
      Issue.record("16-bit predictor samples were decoded")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
    }
  }

  @Test func truncatedCorruptAndUnframedFlateFailExplicitly() throws {
    let payload = Data((0..<512).map { UInt8($0 % 97) })
    let encoded = try PDFFilters.encodeFlate(payload)
    let dictionary: [PDFName: PDFValue] = [PDFName("Filter"): .name(Self.flate)]
    #expect(throws: PDFError.self) {
      _ = try PDFFilters.decoded(
        PDFStream(dictionary: dictionary, bytes: encoded.dropLast(6)))
    }
    var corruptBody = encoded
    corruptBody[corruptBody.startIndex + corruptBody.count / 2] ^= 0xFF
    #expect(throws: PDFError.self) {
      _ = try PDFFilters.decoded(PDFStream(dictionary: dictionary, bytes: corruptBody))
    }
    var corruptChecksum = encoded
    corruptChecksum[corruptChecksum.index(before: corruptChecksum.endIndex)] ^= 0xFF
    #expect(throws: PDFError.self) {
      _ = try PDFFilters.decoded(PDFStream(dictionary: dictionary, bytes: corruptChecksum))
    }
    #expect(throws: PDFError.self) {
      _ = try PDFFilters.decoded(
        PDFStream(dictionary: dictionary, bytes: Data("not zlib".utf8)))
    }
  }

  @Test func decodedOutputIsBoundedByTheConfiguredLimit() throws {
    let payload = Data(repeating: 7, count: 4_096)
    let encoded = try PDFFilters.encodeFlate(payload)
    let stream = PDFStream(dictionary: [PDFName("Filter"): .name(Self.flate)], bytes: encoded)
    #expect(throws: PDFError.self) {
      _ = try PDFFilters.decoded(stream, limits: PDFLimits(decodedBytes: 1_024))
    }
    #expect(
      try PDFFilters.decoded(stream, limits: PDFLimits(decodedBytes: 4_096)) == payload)
  }

  /// Pure-Swift Adler-32 so the check is independent of zlib's optimized code.
  private static func adler32(_ data: Data) -> UInt32 {
    var a: UInt32 = 1
    var b: UInt32 = 0
    for byte in data {
      a = (a + UInt32(byte)) % 65_521
      b = (b + a) % 65_521
    }
    return (b << 16) | a
  }

  private static func appleRawInflate(_ data: Data, expectedSize: Int) -> Data? {
    var output = [UInt8](repeating: 0, count: expectedSize)
    let decoded = output.withUnsafeMutableBytes { rawOutput -> Int in
      data.withUnsafeBytes { rawInput -> Int in
        compression_decode_buffer(
          rawOutput.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
          rawInput.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
      }
    }
    return decoded == expectedSize ? Data(output) : nil
  }
}
