import Compression
import Foundation
import PDFCore

/// P35-003/P35-004: a bounded, deterministic ZIP writer using the system's
/// DEFLATE primitive. Only what OOXML packaging needs is implemented: stored
/// and deflated entries, CRC-32, local headers, a central directory, and the
/// end-of-central-directory record.
public struct ZIPArchiveWriter {
  public struct Limits: Sendable, Equatable {
    public var maxEntries: Int
    public var maxEntryBytes: Int
    public var maxTotalBytes: Int

    public init(
      maxEntries: Int = 4_096, maxEntryBytes: Int = 128 * 1_024 * 1_024,
      maxTotalBytes: Int = 512 * 1_024 * 1_024
    ) {
      self.maxEntries = maxEntries
      self.maxEntryBytes = maxEntryBytes
      self.maxTotalBytes = maxTotalBytes
    }
  }

  public struct Entry: Sendable, Equatable {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) {
      self.name = name
      self.data = data
    }
  }

  private var entries: [Entry] = []
  private let limits: Limits
  private var totalBytes = 0

  public init(limits: Limits = Limits()) {
    self.limits = limits
  }

  public mutating func add(name: String, data: Data) throws {
    guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("..") else {
      throw PDFError(.unsupported, "ZIP entry names must be relative and safe")
    }
    guard entries.count < limits.maxEntries else {
      throw PDFError(.limitExceeded, "The archive exceeds the entry-count limit")
    }
    guard data.count <= limits.maxEntryBytes else {
      throw PDFError(.limitExceeded, "An entry exceeds the per-entry size limit")
    }
    guard totalBytes + data.count <= limits.maxTotalBytes else {
      throw PDFError(.limitExceeded, "The archive exceeds the total size limit")
    }
    entries.append(Entry(name: name, data: data))
    totalBytes += data.count
  }

  /// Deterministic bytes: fixed timestamps, entry order as added, and no
  /// platform-specific metadata.
  public func archive() throws -> Data {
    var output = Data()
    var centralDirectory = Data()
    var offsets: [Int] = []
    for entry in entries {
      offsets.append(output.count)
      let nameBytes = Array(entry.name.utf8)
      let compressed = Self.deflate(entry.data)
      let method: UInt16 = compressed.count < entry.data.count ? 8 : 0
      let payload = method == 8 ? compressed : entry.data
      let crc = Self.crc32(entry.data)
      // Local file header.
      output.appendUInt32(0x0403_4b50)
      output.appendUInt16(20)
      output.appendUInt16(0x0800)  // UTF-8 names
      output.appendUInt16(method)
      output.appendUInt16(0)  // fixed DOS time
      output.appendUInt16(0x21)  // fixed DOS date (1980-01-01)
      output.appendUInt32(crc)
      output.appendUInt32(UInt32(payload.count))
      output.appendUInt32(UInt32(entry.data.count))
      output.appendUInt16(UInt16(nameBytes.count))
      output.appendUInt16(0)
      output.append(contentsOf: nameBytes)
      output.append(payload)

      // Central directory record.
      centralDirectory.appendUInt32(0x0201_4b50)
      centralDirectory.appendUInt16(20)
      centralDirectory.appendUInt16(20)
      centralDirectory.appendUInt16(0x0800)
      centralDirectory.appendUInt16(method)
      centralDirectory.appendUInt16(0)
      centralDirectory.appendUInt16(0x21)
      centralDirectory.appendUInt32(crc)
      centralDirectory.appendUInt32(UInt32(payload.count))
      centralDirectory.appendUInt32(UInt32(entry.data.count))
      centralDirectory.appendUInt16(UInt16(nameBytes.count))
      centralDirectory.appendUInt16(0)
      centralDirectory.appendUInt16(0)
      centralDirectory.appendUInt16(0)
      centralDirectory.appendUInt16(0)
      centralDirectory.appendUInt32(0)
      centralDirectory.appendUInt32(UInt32(offsets[offsets.count - 1]))
      centralDirectory.append(contentsOf: nameBytes)
    }
    let directoryOffset = output.count
    output.append(centralDirectory)
    // End of central directory.
    output.appendUInt32(0x0605_4b50)
    output.appendUInt16(0)
    output.appendUInt16(0)
    output.appendUInt16(UInt16(entries.count))
    output.appendUInt16(UInt16(entries.count))
    output.appendUInt32(UInt32(centralDirectory.count))
    output.appendUInt32(UInt32(directoryOffset))
    output.appendUInt16(0)
    return output
  }

  // MARK: - Primitives

  static func deflate(_ data: Data) -> Data {
    guard !data.isEmpty else { return Data() }
    let scratchSize = compression_encode_scratch_buffer_size(COMPRESSION_ZLIB)
    var scratch = [UInt8](repeating: 0, count: max(scratchSize, 1))
    let capacity = data.count + data.count / 1_000 + 64
    var destination = [UInt8](repeating: 0, count: capacity)
    let written = data.withUnsafeBytes { source -> Int in
      guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
      return compression_encode_buffer(
        &destination, capacity, base, data.count, &scratch, COMPRESSION_ZLIB)
    }
    guard written > 0 else { return Data() }
    return Data(destination.prefix(written))
  }

  static let crcTable: [UInt32] = {
    var table = [UInt32](repeating: 0, count: 256)
    for index in 0..<256 {
      var value = UInt32(index)
      for _ in 0..<8 {
        value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
      }
      table[index] = value
    }
    return table
  }()

  static func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
      crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
  }
}

extension Data {
  mutating func appendUInt16(_ value: UInt16) {
    append(UInt8(value & 0xFF))
    append(UInt8((value >> 8) & 0xFF))
  }

  mutating func appendUInt32(_ value: UInt32) {
    append(UInt8(value & 0xFF))
    append(UInt8((value >> 8) & 0xFF))
    append(UInt8((value >> 16) & 0xFF))
    append(UInt8((value >> 24) & 0xFF))
  }
}
