import Foundation

/// FNT-07: a deterministic variable-font fixture derived from the committed
/// DejaVu Sans subset. The base glyf/hmtx tables stay untouched (they are the
/// default instance); a valid fvar table declares two axes and two named
/// non-default instances. Used to prove capability parsing and the static
/// default-instance embedding profile without an owner variable-font corpus.
public enum VariableFontFixture {
  public static let weightAxisTag = "wght"
  public static let widthAxisTag = "wdth"
  public static let weightMinimum = 100.0
  public static let weightDefault = 400.0
  public static let weightMaximum = 900.0
  public static let widthMinimum = 75.0
  public static let widthDefault = 100.0
  public static let widthMaximum = 125.0

  /// Named instance coordinates (declaration order).
  public static let namedInstances: [(nameID: Int, weight: Double, width: Double)] = [
    (257, 300, 100),  // Light
    (258, 700, 75),   // Condensed Bold
  ]

  /// The base DejaVu Sans subset plus an fvar table. On-disk tables other than
  /// fvar are unchanged, so the embeddable default instance is the base subset.
  public static func program() throws -> Data {
    guard let base = Data(base64Encoded: FontFixtureData.subsetProgramBase64) else {
      throw FixtureError("The base font fixture is corrupt")
    }
    let fvar = fvarTable()
    return try addingTable(tag: "fvar", payload: fvar, to: base)
  }

  /// The same program truncated inside its table directory: capability
  /// inspection must return an explicit malformed result, not crash.
  public static func truncatedProgram() throws -> Data {
    let program = try program()
    return Data(program.prefix(max(64, program.count - 96)))
  }

  public struct FixtureError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
  }

  // MARK: - fvar bytes

  private static func fixed(_ value: Double) -> [UInt8] {
    let raw = Int32((value * 65_536).rounded())
    let bits = UInt32(bitPattern: raw)
    return [
      UInt8((bits >> 24) & 0xFF), UInt8((bits >> 16) & 0xFF),
      UInt8((bits >> 8) & 0xFF), UInt8(bits & 0xFF),
    ]
  }

  private static func fvarTable() -> [UInt8] {
    let axisCount = 2
    let axisSize = 20
    let instanceSize = 4 + axisCount * 4
    var bytes: [UInt8] = []
    func u16(_ value: Int) { bytes += [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
    u16(1)  // majorVersion
    u16(0)  // minorVersion
    u16(16)  // axesArrayOffset: immediately after the header
    u16(2)  // reserved
    u16(axisCount)
    u16(axisSize)
    u16(namedInstances.count)
    u16(instanceSize)
    for axis in [
      (weightAxisTag, weightMinimum, weightDefault, weightMaximum),
      (widthAxisTag, widthMinimum, widthDefault, widthMaximum),
    ] {
      bytes += Array(axis.0.utf8)
      bytes += fixed(axis.1)
      bytes += fixed(axis.2)
      bytes += fixed(axis.3)
      u16(0)  // flags
      u16(256)  // axisNameID
    }
    for instance in namedInstances {
      u16(instance.nameID)
      u16(0)  // flags
      bytes += fixed(instance.weight)
      bytes += fixed(instance.width)
    }
    return bytes
  }

  // MARK: - sfnt table rebuild

  private static func u16(_ bytes: [UInt8], at offset: Int) -> Int {
    Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
  }

  private static func u32(_ bytes: [UInt8], at offset: Int) -> Int {
    var value = 0
    for index in 0..<4 { value = value * 256 + Int(bytes[offset + index]) }
    return value
  }

  private static func writeU16(_ value: Int, into bytes: inout [UInt8], at offset: Int) {
    bytes[offset] = UInt8((value >> 8) & 0xFF)
    bytes[offset + 1] = UInt8(value & 0xFF)
  }

  private static func writeU32(_ value: Int, into bytes: inout [UInt8], at offset: Int) {
    bytes[offset] = UInt8((value >> 24) & 0xFF)
    bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
    bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
    bytes[offset + 3] = UInt8(value & 0xFF)
  }

  private static func checksum(_ bytes: [UInt8]) -> UInt32 {
    var sum: UInt32 = 0
    var index = 0
    while index < bytes.count {
      var word: UInt32 = 0
      for slot in 0..<4 {
        word = word &* 256 &+ UInt32(index + slot < bytes.count ? bytes[index + slot] : 0)
      }
      sum = sum &+ word
      index += 4
    }
    return sum
  }

  private struct TableRecord {
    let tag: [UInt8]
    let data: [UInt8]
  }

  private static func addingTable(
    tag: String, payload: [UInt8], to program: Data
  ) throws -> Data {
    let bytes = [UInt8](program)
    guard bytes.count >= 12 else { throw FixtureError("The base program is too short") }
    let sfnt = u32(bytes, at: 0)
    let tableCount = u16(bytes, at: 4)
    guard tableCount > 0, 12 + tableCount * 16 <= bytes.count else {
      throw FixtureError("The base program directory is invalid")
    }
    var records: [TableRecord] = []
    for index in 0..<tableCount {
      let base = 12 + index * 16
      let tag = Array(bytes[base..<(base + 4)])
      let offset = u32(bytes, at: base + 8)
      let length = u32(bytes, at: base + 12)
      guard offset >= 0, offset + length <= bytes.count else {
        throw FixtureError("A base program table is out of bounds")
      }
      var table = Array(bytes[offset..<(offset + length)])
      if tag == Array("head".utf8), table.count >= 12 {
        for position in 8..<12 { table[position] = 0 }
      }
      records.append(TableRecord(tag: tag, data: table))
    }
    records.append(TableRecord(tag: Array(tag.utf8), data: payload))
    records.sort { $0.tag.lexicographicallyPrecedes($1.tag) }

    let count = records.count
    let headerSize = 12 + count * 16
    var offsets: [Int] = []
    var cursor = headerSize
    for record in records {
      cursor = (cursor + 3) / 4 * 4
      offsets.append(cursor)
      cursor += record.data.count
    }
    let total = (cursor + 3) / 4 * 4
    var output = [UInt8](repeating: 0, count: total)
    var maxPower = 1
    while maxPower * 2 <= count { maxPower *= 2 }
    var entrySelector = 0
    while (1 << (entrySelector + 1)) <= count { entrySelector += 1 }
    writeU32(sfnt, into: &output, at: 0)
    writeU16(count, into: &output, at: 4)
    writeU16(maxPower * 16, into: &output, at: 6)
    writeU16(entrySelector, into: &output, at: 8)
    writeU16(count * 16 - maxPower * 16, into: &output, at: 10)
    var headOffset: Int?
    for (index, record) in records.enumerated() {
      let base = 12 + index * 16
      output.replaceSubrange(base..<(base + 4), with: record.tag)
      writeU32(Int(checksum(record.data)), into: &output, at: base + 4)
      writeU32(offsets[index], into: &output, at: base + 8)
      writeU32(record.data.count, into: &output, at: base + 12)
      output.replaceSubrange(
        offsets[index]..<(offsets[index] + record.data.count), with: record.data)
      if record.tag == Array("head".utf8) { headOffset = offsets[index] }
    }
    if let headOffset, headOffset + 12 <= output.count {
      writeU32(0, into: &output, at: headOffset + 8)
      let adjustment = 0xB1B0_AFBA &- checksum(output)
      writeU32(Int(adjustment), into: &output, at: headOffset + 8)
    }
    return Data(output)
  }
}
