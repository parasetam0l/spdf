import Foundation
import Testing

@testable import PDFCore

/// P07-013–P07-016/P07-018/P07-023/P07-024/P07-028: unsupported-filter
/// preservation and detection, Crypt separation, expansion bombs, and
/// decode cancellation.
@Suite("Unsupported filters and decode safety")
struct UnsupportedFilterTests {
  private func imageStream(
    filter: String, parameters: [PDFName: PDFValue] = [:], bytes: [UInt8] = [0x00]
  ) -> PDFStream {
    var dictionary: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("XObject")),
      PDFName("Subtype"): .name(PDFName("Image")),
      PDFName("Width"): .integer(2),
      PDFName("Height"): .integer(2),
      PDFName("ColorSpace"): .name(PDFName("DeviceGray")),
      PDFName("BitsPerComponent"): .integer(1),
      PDFName("Filter"): .name(PDFName(filter)),
    ]
    if !parameters.isEmpty {
      dictionary[PDFName("DecodeParms")] = .dictionary(parameters)
    }
    return PDFStream(dictionary: dictionary, bytes: Data(bytes))
  }

  @Test func faxAndJBIG2ParametersAreDetected() throws {
    let group4 = try PDFFilters.imageFacts(
      of: imageStream(
        filter: "CCITTFaxDecode",
        parameters: [
          PDFName("K"): .integer(-1), PDFName("Columns"): .integer(1728),
          PDFName("Rows"): .integer(0),
        ]).dictionary)
    #expect(group4.filters == ["CCITTFaxDecode"])
    #expect(group4.ccittParameters == PDFFilters.CCITTParameters(
      k: -1, columns: 1728, rows: 0, blackIs1: false))
    #expect(group4.hasJBIG2Globals == false)
    // Defaults apply per the specification; BlackIs1 honors the dictionary.
    let group3 = try PDFFilters.imageFacts(
      of: imageStream(filter: "CCF", parameters: [PDFName("BlackIs1"): .boolean(true)])
        .dictionary)
    #expect(group3.filters == ["CCF"])
    #expect(group3.ccittParameters?.k == 0)
    #expect(group3.ccittParameters?.columns == 1728)
    #expect(group3.ccittParameters?.rows == nil)
    #expect(group3.ccittParameters?.blackIs1 == true)
    // JBIG2 globals are a presence fact on the same parms dictionary.
    let jbig2 = try PDFFilters.imageFacts(
      of: imageStream(
        filter: "JBIG2Decode",
        parameters: [PDFName("JBIG2Globals"): .reference(PDFObjectID(9))]).dictionary)
    #expect(jbig2.hasJBIG2Globals == true)
    #expect(jbig2.ccittParameters == nil)
    // Aligned filter/parms arrays attribute each entry to its own filter.
    let chained = try PDFFilters.imageFacts(
      of: PDFStream(
        dictionary: [
          PDFName("Filter"): .array([
            .name(PDFName("ASCII85Decode")), .name(PDFName("CCITTFaxDecode")),
          ]),
          PDFName("DecodeParms"): .array([
            .null,
            .dictionary([
              PDFName("K"): .integer(-1), PDFName("Columns"): .integer(2048),
            ]),
          ]),
        ], bytes: Data()).dictionary)
    #expect(chained.filters == ["ASCII85Decode", "CCITTFaxDecode"])
    #expect(chained.ccittParameters?.columns == 2048)
  }

  @Test func decodingRefusesUnsupportedAndCryptFilters() {
    let dct = imageStream(filter: "DCTDecode", bytes: [0xFF, 0xD8, 0xFF, 0xD9])
    #expect(throws: PDFError.self) { try PDFFilters.decoded(dct) }
    do {
      _ = try PDFFilters.decoded(dct)
      Issue.record("DCTDecode should refuse")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
    } catch {
      Issue.record("wrong error type \(error)")
    }
    // P07-018: Crypt filters belong to the encryption pipeline, never to
    // ordinary decoding.
    let crypt = imageStream(filter: "Crypt")
    do {
      _ = try PDFFilters.decoded(crypt)
      Issue.record("Crypt should refuse")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
      #expect(error.message.contains("encryption pipeline"))
    } catch {
      Issue.record("wrong error type \(error)")
    }
  }

  @Test func expansionBombsHitTheDecodedBytesLimit() throws {
    // 100 bytes of zeros inflate far past a 1 KiB budget: bounded failure,
    // never an unbounded allocation.
    let bomb = try PDFFilters.encodeFlate(Data(repeating: 0, count: 100_000))
    #expect(throws: PDFError.self) {
      try PDFFilters.decoded(
        PDFStream(
          dictionary: [PDFName("Filter"): .name(PDFName("FlateDecode"))],
          bytes: bomb),
        limits: PDFLimits(decodedBytes: 1024))
    }
    do {
      _ = try PDFFilters.decoded(
        PDFStream(
          dictionary: [PDFName("Filter"): .name(PDFName("FlateDecode"))],
          bytes: bomb),
        limits: PDFLimits(decodedBytes: 1024))
      Issue.record("expected a limit error")
    } catch let error as PDFError {
      #expect(error.kind == .limitExceeded)
    } catch {
      Issue.record("wrong error type \(error)")
    }
  }

  @Test func cancelledDecodesStopPromptly() async throws {
    let bomb = try PDFFilters.encodeFlate(Data(repeating: 0, count: 1_000_000))
    let stream = PDFStream(
      dictionary: [PDFName("Filter"): .name(PDFName("FlateDecode"))], bytes: bomb)
    let task = Task.detached {
      try PDFFilters.decoded(stream)
    }
    task.cancel()
    await #expect(throws: CancellationError.self) {
      try await task.value
    }
  }
}
