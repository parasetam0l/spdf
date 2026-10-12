import Foundation
import zlib

/// Stream filter handling for the owned core.
///
/// PDF FlateDecode streams use the zlib format (RFC 1950). The selected
/// system API is the `zlib` module: its `inflate` accepts the zlib wrapper
/// and verifies the Adler-32 checksum. Apple's Compression
/// `COMPRESSION_ZLIB` instead operates on raw DEFLATE without the zlib
/// wrapper, so using it for PDF input would require manual framing and
/// checksum handling.
///
/// Supported filters: FlateDecode/Fl (system zlib), LZWDecode/LZW
/// (including EarlyChange), ASCIIHexDecode/AHx, ASCII85Decode/A85, and
/// RunLengthDecode/RL, plus TIFF and PNG predictors for Flate/LZW
/// parameters with 8-bit samples. Output is produced in bounded chunks
/// with cancellation checks; every stage fails explicitly when it exceeds
/// `PDFLimits.decodedBytes`. Unsupported filters keep raw bytes preserved
/// elsewhere instead of guessing at their content.
public enum PDFFilters {
  /// Filter names from /Filter; an empty list means the stream is unfiltered.
  public static func filterNames(in dictionary: [PDFName: PDFValue]) throws -> [PDFName] {
    switch dictionary[PDFName("Filter")] {
    case nil, .some(.null):
      return []
    case .some(.name(let name)):
      return [name]
    case .some(.array(let values)):
      guard values.count <= 64 else {
        throw PDFError(.limitExceeded, "Stream filter chain exceeds the configured limit")
      }
      var names: [PDFName] = []
      for value in values {
        guard case .name(let name) = value else {
          throw PDFError(.malformed, "Stream filter list contains a non-name entry")
        }
        names.append(name)
      }
      return names
    case .some:
      throw PDFError(.malformed, "Stream filter entry is not a name or array")
    }
  }

  /// DecodeParms aligned one-to-one with the filter names.
  public static func decodeParms(
    in dictionary: [PDFName: PDFValue], filterCount: Int
  ) throws -> [PDFValue] {
    guard filterCount >= 0 else {
      throw PDFError(.malformed, "Stream filter count is invalid")
    }
    guard let value = dictionary[PDFName("DecodeParms")] ?? dictionary[PDFName("DP")] else {
      return Array(repeating: .null, count: filterCount)
    }
    switch value {
    case .null:
      return Array(repeating: .null, count: filterCount)
    case .dictionary:
      guard filterCount == 1 else {
        throw PDFError(.malformed, "DecodeParms must be an aligned array for multiple filters")
      }
      return [value]
    case .array(let values):
      guard values.count == filterCount else {
        throw PDFError(.malformed, "DecodeParms does not align with the stream filter list")
      }
      for entry in values {
        guard case .dictionary = entry else {
          guard case .null = entry else {
            throw PDFError(.malformed, "DecodeParms entry is not a dictionary or null")
          }
          continue
        }
      }
      return values
    default:
      throw PDFError(.malformed, "DecodeParms is not a dictionary, array, or null")
    }
  }

  /// Decode a stream to its unfiltered bytes by applying the filter chain in
  /// the specified order. Unsupported filters fail with an explicit result.
  public static func decoded(_ stream: PDFStream, limits: PDFLimits = PDFLimits()) throws -> Data {
    let names = try filterNames(in: stream.dictionary)
    guard !names.isEmpty else { return stream.bytes }
    let parms = try decodeParms(in: stream.dictionary, filterCount: names.count)
    var data = stream.bytes
    for (index, name) in names.enumerated() {
      try Task.checkCancellation()
      switch name {
      case PDFName("FlateDecode"), PDFName("Fl"):
        data = try inflate(data, limits: limits)
        data = try applyPredictor(data, parms: parms[index], limits: limits)
      case PDFName("LZWDecode"), PDFName("LZW"):
        data = try lzwDecode(data, parms: parms[index], limits: limits)
        data = try applyPredictor(data, parms: parms[index], limits: limits)
      case PDFName("ASCIIHexDecode"), PDFName("AHx"):
        data = try asciiHexDecode(data, limits: limits)
      case PDFName("ASCII85Decode"), PDFName("A85"):
        data = try ascii85Decode(data, limits: limits)
      case PDFName("RunLengthDecode"), PDFName("RL"):
        data = try runLengthDecode(data, limits: limits)
      case PDFName("Crypt"):
        throw PDFError(.unsupported, "Crypt filters belong to the encryption pipeline")
      default:
        throw PDFError(.unsupported, "Stream filter is not supported for decoding yet")
      }
    }
    return data
  }

  /// P07-015/P07-016: detected parameters of fax and JBIG2 image streams.
  /// The core preserves these payloads verbatim and never decodes them; the
  /// facts exist so inventories and refusals can name exact parameters.
  public struct CCITTParameters: Sendable, Equatable {
    /// K: 0 is Group 3 one-dimensional, positive is Group 3 two-dimensional,
    /// negative is Group 4.
    public let k: Int
    public let columns: Int
    public let rows: Int?
    public let blackIs1: Bool

    public init(k: Int, columns: Int, rows: Int?, blackIs1: Bool) {
      self.k = k
      self.columns = columns
      self.rows = rows
      self.blackIs1 = blackIs1
    }
  }

  public struct CompressedImageFacts: Sendable, Equatable {
    public let filters: [String]
    public let ccittParameters: CCITTParameters?
    public let hasJBIG2Globals: Bool

    public init(filters: [String], ccittParameters: CCITTParameters?, hasJBIG2Globals: Bool) {
      self.filters = filters
      self.ccittParameters = ccittParameters
      self.hasJBIG2Globals = hasJBIG2Globals
    }
  }

  /// Read filter and fax/JBIG2 facts from an image dictionary without
  /// decoding anything. Never throws for missing keys (absence is a fact);
  /// malformed filter lists still throw like `filterNames`.
  public static func imageFacts(of dictionary: [PDFName: PDFValue]) throws
    -> CompressedImageFacts
  {
    let names = try filterNames(in: dictionary)
    let filterNames = names.map { String(decoding: $0.bytes, as: UTF8.self) }
    var parms: [PDFValue] = []
    if let value = dictionary[PDFName("DecodeParms")] ?? dictionary[PDFName("DP")] {
      switch value {
      case .null:
        parms = Array(repeating: .null, count: names.count)
      case .dictionary:
        parms = names.count == 1 ? [value] : []
      case .array(let values):
        parms = values.count == names.count ? values : []
      default:
        parms = []
      }
    }
    var ccitt: CCITTParameters?
    var globals = false
    for (index, name) in names.enumerated() {
      let parameters: [PDFName: PDFValue]
      if index < parms.count, case .dictionary(let dictionary) = parms[index] {
        parameters = dictionary
      } else {
        parameters = [:]
      }
      func integer(_ key: String) -> Int? {
        if case .integer(let number)? = parameters[PDFName(key)] {
          return Int(exactly: number)
        }
        return nil
      }
      func boolean(_ key: String) -> Bool? {
        if case .boolean(let flag)? = parameters[PDFName(key)] { return flag }
        return nil
      }
      switch name {
      case PDFName("CCITTFaxDecode"), PDFName("CCF"):
        // Defaults per the PDF specification: K 0, BlackIs1 false;
        // Columns defaults to 1728, Rows may be absent (0/unspecified).
        ccitt = CCITTParameters(
          k: integer("K") ?? 0, columns: integer("Columns") ?? 1728,
          rows: integer("Rows"), blackIs1: boolean("BlackIs1") ?? false)
      case PDFName("JBIG2Decode"):
        if parameters[PDFName("JBIG2Globals")] != nil { globals = true }
      default:
        break
      }
    }
    return CompressedImageFacts(
      filters: filterNames, ccittParameters: ccitt, hasJBIG2Globals: globals)
  }

  /// Encode bytes as a zlib-framed FlateDecode payload. Used by fixtures and
  /// tooling; the writer still preserves untouched raw stream bytes.
  public static func encodeFlate(_ data: Data, limits: PDFLimits = PDFLimits()) throws -> Data {
    guard data.count <= limits.streamBytes else {
      throw PDFError(.limitExceeded, "Stream exceeds the configured limit before encoding")
    }
    var output = Data(count: Int(compressBound(uLong(data.count))))
    guard !output.isEmpty else {
      throw PDFError(.limitExceeded, "Flate encoding buffer is unavailable")
    }
    var outputLength = uLongf(output.count)
    let status: Int32 = output.withUnsafeMutableBytes { rawOutput in
      let destination = rawOutput.bindMemory(to: Bytef.self).baseAddress
      if data.isEmpty {
        var empty: UInt8 = 0
        return withUnsafePointer(to: &empty) { source in
          compress2(destination, &outputLength, source, 0, Z_DEFAULT_COMPRESSION)
        }
      }
      return data.withUnsafeBytes { rawInput in
        compress2(
          destination, &outputLength, rawInput.bindMemory(to: Bytef.self).baseAddress,
          uLong(data.count), Z_DEFAULT_COMPRESSION)
      }
    }
    guard status == Z_OK, outputLength <= uLong(output.count) else {
      throw PDFError(.limitExceeded, "Flate encoding failed")
    }
    output.removeSubrange(Int(outputLength)..<output.count)
    return output
  }

  // MARK: - FlateDecode

  /// Streaming zlib inflate with a bounded output buffer and checksum
  /// verification performed by zlib itself.
  static func inflate(_ input: Data, limits: PDFLimits) throws -> Data {
    var stream = z_stream()
    guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
      throw PDFError(.limitExceeded, "Flate decoding could not be initialized")
    }
    defer { inflateEnd(&stream) }
    let chunkBytes = 64 * 1_024
    var buffer = [UInt8](repeating: 0, count: chunkBytes)
    var output = Data()
    var finished = false
    try input.withUnsafeBytes { rawInput in
      stream.next_in = UnsafeMutablePointer(mutating: rawInput.bindMemory(to: Bytef.self).baseAddress)
      stream.avail_in = uInt(rawInput.count)
      while !finished {
        try Task.checkCancellation()
        var status: Int32 = Z_OK
        var produced = 0
        buffer.withUnsafeMutableBytes { rawOutput in
          stream.next_out = rawOutput.bindMemory(to: Bytef.self).baseAddress
          stream.avail_out = uInt(chunkBytes)
          status = zlib.inflate(&stream, Z_NO_FLUSH)
          produced = chunkBytes - Int(stream.avail_out)
        }
        if produced > 0 {
          try appendBounded(&output, buffer[0..<produced], limits: limits)
        }
        switch status {
        case Z_STREAM_END:
          finished = true
        case Z_OK:
          guard produced > 0 else {
            throw PDFError(
              .malformed, "FlateDecode data ends before the zlib end-of-stream marker")
          }
        case Z_BUF_ERROR:
          throw PDFError(.malformed, "FlateDecode data ends before the zlib end-of-stream marker")
        case Z_DATA_ERROR:
          throw PDFError(.malformed, "FlateDecode data or its checksum is invalid")
        case Z_MEM_ERROR:
          throw PDFError(.limitExceeded, "Flate decoding ran out of memory")
        default:
          throw PDFError(.malformed, "FlateDecode failed")
        }
      }
    }
    return output
  }

  // MARK: - ASCIIHexDecode

  static func asciiHexDecode(_ input: Data, limits: PDFLimits) throws -> Data {
    var output = Data()
    var pending: UInt8?
    for byte in input {
      try Task.checkCancellation()
      if byte == 62 {  // >
        if let nibble = pending {
          try appendBounded(&output, [nibble << 4], limits: limits)
        }
        return output
      }
      if ByteCursor.isWhitespace(byte) { continue }
      guard let nibble = hexNibble(byte) else {
        throw PDFError(.malformed, "ASCIIHex data contains a non-hex character")
      }
      if let high = pending {
        try appendBounded(&output, [(high << 4) | nibble], limits: limits)
        pending = nil
      } else {
        pending = nibble
      }
    }
    throw PDFError(.malformed, "ASCIIHex data is missing its terminator")
  }

  // MARK: - ASCII85Decode

  static func ascii85Decode(_ input: Data, limits: PDFLimits) throws -> Data {
    let bytes = [UInt8](input)
    var position = 0
    while position < bytes.count, ByteCursor.isWhitespace(bytes[position]) { position += 1 }
    if position + 1 < bytes.count, bytes[position] == 60, bytes[position + 1] == 126 {
      position += 2  // optional <~ prefix
    }
    var output = Data()
    var tuple: [Int] = []
    while true {
      try Task.checkCancellation()
      guard position < bytes.count else {
        throw PDFError(.malformed, "ASCII85 data is missing its terminator")
      }
      let byte = bytes[position]
      position += 1
      if ByteCursor.isWhitespace(byte) { continue }
      if byte == 126, position < bytes.count, bytes[position] == 62 {  // ~>
        position += 1
        guard tuple.count != 1 else {
          throw PDFError(.malformed, "ASCII85 ends inside a partial group")
        }
        if tuple.count > 1 {
          let keep = tuple.count - 1
          while tuple.count < 5 { tuple.append(84) }
          let value = try ascii85Value(tuple)
          let full: [UInt8] = [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
          ]
          try appendBounded(&output, full[0..<keep], limits: limits)
        }
        return output
      }
      if byte == 122 {  // z
        guard tuple.isEmpty else {
          throw PDFError(.malformed, "ASCII85 'z' appears inside a group")
        }
        try appendBounded(&output, [0, 0, 0, 0], limits: limits)
        continue
      }
      guard (33...117).contains(byte) else {
        throw PDFError(.malformed, "ASCII85 data contains an invalid character")
      }
      tuple.append(Int(byte - 33))
      if tuple.count == 5 {
        let value = try ascii85Value(tuple)
        try appendBounded(
          &output,
          [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
          ], limits: limits)
        tuple.removeAll(keepingCapacity: true)
      }
    }
  }

  private static func ascii85Value(_ tuple: [Int]) throws -> Int {
    var value = 0
    for digit in tuple { value = value * 85 + digit }
    guard value <= 0xFFFF_FFFF else {
      throw PDFError(.malformed, "ASCII85 group exceeds the 32-bit range")
    }
    return value
  }

  // MARK: - RunLengthDecode

  static func runLengthDecode(_ input: Data, limits: PDFLimits) throws -> Data {
    let bytes = [UInt8](input)
    var output = Data()
    var position = 0
    while position < bytes.count {
      try Task.checkCancellation()
      let length = Int(bytes[position])
      position += 1
      switch length {
      case 128:
        return output
      case 0...127:
        let count = length + 1
        guard count <= bytes.count - position else {
          throw PDFError(.malformed, "RunLength data is truncated")
        }
        try appendBounded(&output, bytes[position..<(position + count)], limits: limits)
        position += count
      default:
        guard position < bytes.count else {
          throw PDFError(.malformed, "RunLength data is truncated")
        }
        let value = bytes[position]
        position += 1
        try appendBounded(
          &output, Array(repeating: value, count: 257 - length), limits: limits)
      }
    }
    throw PDFError(.malformed, "RunLength data is missing its end-of-data marker")
  }

  // MARK: - LZWDecode

  static func lzwDecode(_ input: Data, parms: PDFValue, limits: PDFLimits) throws -> Data {
    let earlyChange = try lzwEarlyChange(parms)
    var reader = MSBBitReader(bytes: [UInt8](input))
    var table: [[UInt8]] = Self.initialLZWTable()
    var codeWidth = 9
    var nextCode = 258
    var previous: [UInt8]?
    var output = Data()
    while true {
      try Task.checkCancellation()
      guard let code = try reader.read(codeWidth) else {
        throw PDFError(.malformed, "LZW data ends before the end-of-data code")
      }
      if code == 256 {
        table = Self.initialLZWTable()
        codeWidth = 9
        nextCode = 258
        previous = nil
        continue
      }
      if code == 257 { return output }
      let entry: [UInt8]
      if code < table.count {
        entry = table[code]
      } else if code == nextCode, let previous, !previous.isEmpty {
        entry = previous + [previous[0]]
      } else {
        throw PDFError(.malformed, "LZW code is outside its table")
      }
      try appendBounded(&output, entry, limits: limits)
      if let previous, nextCode < 4_096 {
        var grown = previous
        grown.append(entry[0])
        table.append(grown)
        nextCode += 1
        if codeWidth < 12, nextCode == (1 << codeWidth) - earlyChange {
          codeWidth += 1
        }
      }
      previous = entry
    }
  }

  private static func lzwEarlyChange(_ parms: PDFValue) throws -> Int {
    guard case .dictionary(let dictionary) = parms else { return 1 }
    guard let value = dictionary[PDFName("EarlyChange")] else { return 1 }
    guard case .integer(let raw) = value, raw == 0 || raw == 1 else {
      throw PDFError(.malformed, "LZW EarlyChange must be 0 or 1")
    }
    return Int(raw)
  }

  private static func initialLZWTable() -> [[UInt8]] {
    // Codes 256 (Clear) and 257 (EOD) are handled before table lookup, but
    // real entries start at code 258, so the table stays indexed by code.
    var table = (0..<256).map { [UInt8($0)] }
    table.append([])
    table.append([])
    return table
  }

  struct MSBBitReader {
    let bytes: [UInt8]
    var bitOffset = 0

    mutating func read(_ count: Int) throws -> Int? {
      guard count > 0, count <= 24 else {
        throw PDFError(.malformed, "Bit width is invalid")
      }
      guard bitOffset <= bytes.count * 8 - count else { return nil }
      var value = 0
      for _ in 0..<count {
        let byte = bytes[bitOffset >> 3]
        value = (value << 1) | Int((byte >> (7 - (bitOffset & 7))) & 1)
        bitOffset += 1
      }
      return value
    }
  }

  // MARK: - Predictors

  struct PredictorParameters: Sendable {
    let predictor: Int
    let colors: Int
    let columns: Int
  }

  /// Parse predictor parameters; nil when the identity predictor (or no
  /// parameters) applies. Only 8-bit sample depths are implemented.
  static func predictorParameters(_ parms: PDFValue) throws -> PredictorParameters? {
    guard case .dictionary(let dictionary) = parms else { return nil }
    let predictor = try parameterInteger(
      dictionary[PDFName("Predictor")], default: 1, name: "Predictor")
    guard predictor != 1 else { return nil }
    guard (2...15).contains(predictor) else {
      throw PDFError(.unsupported, "Predictor value is not supported")
    }
    let colors = try parameterInteger(
      dictionary[PDFName("Colors")], default: 1, name: "Colors")
    let bits = try parameterInteger(
      dictionary[PDFName("BitsPerComponent")], default: 8, name: "BitsPerComponent")
    guard bits == 8 else {
      throw PDFError(.unsupported, "Predictor sample depths other than 8 bits are not implemented")
    }
    guard let rawColumns = dictionary[PDFName("Columns")] else {
      throw PDFError(.malformed, "Predictor parameters require Columns")
    }
    let columns = try parameterInteger(
      Optional(rawColumns), default: 0, name: "Columns")
    guard colors >= 1, colors <= 64, columns >= 1 else {
      throw PDFError(.malformed, "Predictor dimensions are invalid")
    }
    return PredictorParameters(predictor: predictor, colors: colors, columns: columns)
  }

  static func parameterInteger(_ value: PDFValue?, default defaultValue: Int, name: String)
    throws -> Int
  {
    guard let value else { return defaultValue }
    guard case .integer(let raw) = value, let result = Int(exactly: raw) else {
      throw PDFError(.malformed, "Decode parameter is not an integer")
    }
    return result
  }

  static func applyPredictor(_ data: Data, parms: PDFValue, limits: PDFLimits) throws -> Data {
    guard let parameters = try predictorParameters(parms) else { return data }
    // P07-012: validate dimensions before allocating row buffers.
    let (rowBytes, overflow) = parameters.columns.multipliedReportingOverflow(
      by: parameters.colors)
    guard !overflow, rowBytes >= 1, rowBytes <= limits.decodedBytes else {
      throw PDFError(.limitExceeded, "Predictor row size exceeds the configured limit")
    }
    let input = [UInt8](data)
    switch parameters.predictor {
    case 2:
      return try tiffPredictor(
        input, rowBytes: rowBytes, colors: parameters.colors, limits: limits)
    default:
      let fixedFilter = (10...14).contains(parameters.predictor)
        ? parameters.predictor - 10 : nil
      return try pngPredictor(
        input, rowBytes: rowBytes, bytesPerPixel: parameters.colors,
        fixedFilter: fixedFilter, limits: limits)
    }
  }

  static func tiffPredictor(
    _ input: [UInt8], rowBytes: Int, colors: Int, limits: PDFLimits
  ) throws -> Data {
    var output = Data()
    var position = 0
    while position < input.count {
      try Task.checkCancellation()
      let rowLength = min(rowBytes, input.count - position)
      var row = Array(input[position..<(position + rowLength)])
      if rowLength > colors {
        for index in colors..<rowLength {
          row[index] = row[index] &+ row[index - colors]
        }
      }
      try appendBounded(&output, row, limits: limits)
      position += rowLength
    }
    return output
  }

  static func pngPredictor(
    _ input: [UInt8], rowBytes: Int, bytesPerPixel: Int, fixedFilter: Int?, limits: PDFLimits
  ) throws -> Data {
    var output = Data()
    var previousRow = [UInt8](repeating: 0, count: rowBytes)
    var position = 0
    while position < input.count {
      try Task.checkCancellation()
      let filter = Int(input[position])
      position += 1
      guard (0...4).contains(filter), fixedFilter == nil || filter == fixedFilter else {
        throw PDFError(.malformed, "PNG predictor row filter is invalid")
      }
      let rowLength = min(rowBytes, input.count - position)
      var row = Array(input[position..<(position + rowLength)])
      position += rowLength
      for index in 0..<rowLength {
        let left = index >= bytesPerPixel ? row[index - bytesPerPixel] : 0
        let up = previousRow[index]
        let upLeft = index >= bytesPerPixel ? previousRow[index - bytesPerPixel] : 0
        switch filter {
        case 0: break
        case 1: row[index] = row[index] &+ left
        case 2: row[index] = row[index] &+ up
        case 3: row[index] = row[index] &+ UInt8((Int(left) + Int(up)) / 2)
        default: row[index] = row[index] &+ paeth(Int(left), Int(up), Int(upLeft))
        }
      }
      try appendBounded(&output, row, limits: limits)
      previousRow = row + Array(repeating: 0, count: rowBytes - rowLength)
    }
    return output
  }

  static func paeth(_ a: Int, _ b: Int, _ c: Int) -> UInt8 {
    let estimate = a + b - c
    let distanceA = abs(estimate - a)
    let distanceB = abs(estimate - b)
    let distanceC = abs(estimate - c)
    if distanceA <= distanceB, distanceA <= distanceC { return UInt8(a) }
    if distanceB <= distanceC { return UInt8(b) }
    return UInt8(c)
  }

  // MARK: - Shared helpers

  static func appendBounded<S: Collection>(
    _ output: inout Data, _ bytes: S, limits: PDFLimits
  ) throws where S.Element == UInt8 {
    guard output.count <= limits.decodedBytes, bytes.count <= limits.decodedBytes - output.count else {
      throw PDFError(.limitExceeded, "Decoded stream exceeds the configured limit")
    }
    output.append(contentsOf: bytes)
  }

  static func hexNibble(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 48...57: byte - 48
    case 65...70: byte - 55
    case 97...102: byte - 87
    default: nil
    }
  }
}
