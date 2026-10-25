import CryptoKit
import Foundation
import PDFCore

/// FNT-01: one sfnt face extracted from a user-provided font file. A regular
/// TrueType/OpenType file yields one face whose program is the file verbatim;
/// a TrueType collection ('ttcf') yields one standalone program per face so the
/// writer embeds exactly the face the user chose, never another member of the
/// collection.
public struct ExtractedFontFace: Sendable, Equatable {
  public let faceIndex: Int
  /// The face's sfnt version (0x00010000, 'true', 'OTTO').
  public let sfntVersion: UInt32
  /// A standalone sfnt program for this face.
  public let program: Data
  /// True when this face came from a collection and its directory was rebuilt
  /// into a standalone program.
  public let wasExtractedFromCollection: Bool
  public var programDigest: String { FontImportDigest.sha256Hex(program) }

  public init(
    faceIndex: Int, sfntVersion: UInt32, program: Data, wasExtractedFromCollection: Bool
  ) {
    self.faceIndex = faceIndex
    self.sfntVersion = sfntVersion
    self.program = program
    self.wasExtractedFromCollection = wasExtractedFromCollection
  }
}

/// Stable content identity for font programs. Face identity is derived from
/// the program bytes (plus the face index), so selecting a different face or a
/// changed file can never reuse another face's accepted license record.
public enum FontImportDigest {
  public static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public enum FontImportError: Error, LocalizedError, Equatable {
  case notAFontFile(String)
  case unsupportedFormat(String)
  case malformed(String)
  case tooLarge(String)
  case tooManyFaces(String)

  public var errorDescription: String? {
    switch self {
    case .notAFontFile(let message), .unsupportedFormat(let message), .malformed(let message),
      .tooLarge(let message), .tooManyFaces(let message):
      return message
    }
  }
}

/// Bounded sfnt/TTC directory reader. Every offset and length is checked
/// against the file bytes before use; a collection face is rebuilt into a
/// standalone, checksum-correct sfnt so the existing inspector/subsetter/writer
/// path can embed exactly that face.
public enum FontFaceExtractor {
  public struct Limits: Sendable, Equatable {
    public var maxFileBytes: Int
    public var maxFaces: Int
    public var maxTables: Int

    public init(
      maxFileBytes: Int = 20 * 1_024 * 1_024, maxFaces: Int = 64, maxTables: Int = 64
    ) {
      self.maxFileBytes = maxFileBytes
      self.maxFaces = maxFaces
      self.maxTables = maxTables
    }
  }

  static let collectionTag: UInt32 = 0x7474_6366  // 'ttcf'
  private static let trueTag: UInt32 = 0x7472_7565  // 'true'
  private static let openTypeTag: UInt32 = 0x4F54_544F  // 'OTTO'
  private static let wholeFileChecksum: UInt32 = 0xB1B0_AFBA

  static func isSupportedSfntVersion(_ version: UInt32) -> Bool {
    version == 0x0001_0000 || version == trueTag || version == openTypeTag
  }

  /// Extract every face in the data. A single-face file is returned verbatim
  /// (byte-identical to the user's file); a collection is parsed and each face
  /// is rebuilt as a standalone program.
  public static func extractFaces(
    from data: Data, limits: Limits = .init()
  ) throws -> [ExtractedFontFace] {
    guard data.count >= 12 else {
      throw FontImportError.notAFontFile("The selected file is too small to be a font.")
    }
    guard data.count <= limits.maxFileBytes else {
      throw FontImportError.tooLarge("The selected font file exceeds the 20 MB import bound.")
    }
    let bytes = [UInt8](data)
    let signature = UInt32(truncatingIfNeeded: try readU32(bytes, at: 0))
    if signature == collectionTag {
      let faceCount = try readU32(bytes, at: 8)
      guard faceCount > 0 else {
        throw FontImportError.malformed("The font collection declares no faces.")
      }
      guard faceCount <= limits.maxFaces else {
        throw FontImportError.tooManyFaces(
          "The font collection has more than \(limits.maxFaces) faces.")
      }
      let (tableEnd, overflow) = 12.addingReportingOverflow(faceCount * 4)
      guard !overflow, tableEnd <= bytes.count else {
        throw FontImportError.malformed("The font collection directory is truncated.")
      }
      var faces: [ExtractedFontFace] = []
      faces.reserveCapacity(faceCount)
      for index in 0..<faceCount {
        let directoryOffset = try readU32(bytes, at: 12 + index * 4)
        let directory = try readDirectory(bytes, at: directoryOffset, limits: limits)
        faces.append(
          ExtractedFontFace(
            faceIndex: index, sfntVersion: directory.sfntVersion,
            program: try rebuildStandalone(directory: directory, bytes: bytes),
            wasExtractedFromCollection: true))
      }
      return faces
    }
    guard isSupportedSfntVersion(signature) else {
      throw FontImportError.unsupportedFormat(
        "The selected file is not a TrueType or OpenType font. PostScript and bitmap fonts are not supported.")
    }
    _ = try readDirectory(bytes, at: 0, limits: limits)
    return [
      ExtractedFontFace(
        faceIndex: 0, sfntVersion: signature, program: data, wasExtractedFromCollection: false)
    ]
  }

  private struct TableRecord {
    let tag: [UInt8]
    let checksum: UInt32
    let offset: Int
    let length: Int
  }

  private struct FaceDirectory {
    let sfntVersion: UInt32
    let records: [TableRecord]
  }

  private static func readDirectory(
    _ bytes: [UInt8], at directoryOffset: Int, limits: Limits
  ) throws -> FaceDirectory {
    let version = UInt32(truncatingIfNeeded: try readU32(bytes, at: directoryOffset))
    guard isSupportedSfntVersion(version) else {
      throw FontImportError.unsupportedFormat(
        "A face in this file is not a supported TrueType or OpenType program.")
    }
    let tableCount = try readU16(bytes, at: directoryOffset + 4)
    guard tableCount > 0, tableCount <= limits.maxTables else {
      throw FontImportError.malformed("A font face declares an implausible table count.")
    }
    let (directoryEnd, overflow) = directoryOffset.addingReportingOverflow(12 + tableCount * 16)
    guard !overflow, directoryEnd <= bytes.count else {
      throw FontImportError.malformed("A font face table directory runs past the file.")
    }
    var records: [TableRecord] = []
    records.reserveCapacity(tableCount)
    for index in 0..<tableCount {
      let base = directoryOffset + 12 + index * 16
      let tag = Array(bytes[base..<base + 4])
      let checksum = UInt32(truncatingIfNeeded: try readU32(bytes, at: base + 4))
      let offset = try readU32(bytes, at: base + 8)
      let length = try readU32(bytes, at: base + 12)
      let (end, tableOverflow) = offset.addingReportingOverflow(length)
      guard !tableOverflow, offset >= 0, end <= bytes.count else {
        throw FontImportError.malformed("A font table runs past the end of the file.")
      }
      records.append(TableRecord(tag: tag, checksum: checksum, offset: offset, length: length))
    }
    guard Set(records.map { $0.tag }).count == records.count else {
      throw FontImportError.malformed("A font face declares duplicate tables.")
    }
    return FaceDirectory(sfntVersion: version, records: records)
  }

  /// Rebuild one collection face as a standalone sfnt: a sorted table
  /// directory, re-offset table data, recomputed table checksums and a valid
  /// whole-file checkSumAdjustment.
  private static func rebuildStandalone(
    directory: FaceDirectory, bytes: [UInt8]
  ) throws -> Data {
    let records = directory.records.sorted { $0.tag.lexicographicallyPrecedes($1.tag) }
    let tableCount = records.count
    let headerSize = 12 + tableCount * 16
    var offsets: [Int] = []
    var cursor = headerSize
    for record in records {
      cursor = (cursor + 3) / 4 * 4
      offsets.append(cursor)
      cursor += record.length
    }
    let total = (cursor + 3) / 4 * 4
    var output = [UInt8](repeating: 0, count: total)

    let maxPower = largestPowerOfTwo(notExceeding: tableCount)
    var entrySelector = 0
    while (1 << (entrySelector + 1)) <= tableCount { entrySelector += 1 }
    writeU32(directory.sfntVersion, into: &output, at: 0)
    writeU16(tableCount, into: &output, at: 4)
    writeU16(maxPower * 16, into: &output, at: 6)
    writeU16(entrySelector, into: &output, at: 8)
    writeU16(tableCount * 16 - maxPower * 16, into: &output, at: 10)

    var headOffset: Int?
    for (index, record) in records.enumerated() {
      var table = Array(bytes[record.offset..<(record.offset + record.length)])
      // Per spec, a table's checksum is computed with the head table's
      // checkSumAdjustment zeroed; the value is restored after the file sum.
      if record.tag == Array("head".utf8), table.count >= 12 {
        for position in 8..<12 { table[position] = 0 }
        headOffset = offsets[index]
      }
      let checksum = checksum32(table)
      let base = 12 + index * 16
      output.replaceSubrange(base..<(base + 4), with: record.tag)
      writeU32(checksum, into: &output, at: base + 4)
      writeU32(UInt32(offsets[index]), into: &output, at: base + 8)
      writeU32(UInt32(record.length), into: &output, at: base + 12)
      output.replaceSubrange(offsets[index]..<(offsets[index] + record.length), with: table)
    }
    if let headOffset, headOffset + 12 <= output.count {
      writeU32(0, into: &output, at: headOffset + 8)
      let adjustment = wholeFileChecksum &- checksum32(output)
      writeU32(adjustment, into: &output, at: headOffset + 8)
    }
    return Data(output)
  }

  static func checksum32(_ bytes: [UInt8]) -> UInt32 {
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

  static func largestPowerOfTwo(notExceeding value: Int) -> Int {
    var power = 1
    while power * 2 <= value { power *= 2 }
    return power
  }

  private static func readU16(_ bytes: [UInt8], at offset: Int) throws -> Int {
    guard offset >= 0, offset + 2 <= bytes.count else {
      throw FontImportError.malformed("A font header read is outside the file.")
    }
    return Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
  }

  private static func readU32(_ bytes: [UInt8], at offset: Int) throws -> Int {
    guard offset >= 0, offset + 4 <= bytes.count else {
      throw FontImportError.malformed("A font header read is outside the file.")
    }
    var value = 0
    for position in 0..<4 { value = value * 256 + Int(bytes[offset + position]) }
    return value
  }

  private static func writeU16(_ value: Int, into bytes: inout [UInt8], at offset: Int) {
    guard offset >= 0, offset + 2 <= bytes.count else { return }
    bytes[offset] = UInt8((value >> 8) & 0xFF)
    bytes[offset + 1] = UInt8(value & 0xFF)
  }

  private static func writeU32(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
    guard offset >= 0, offset + 4 <= bytes.count else { return }
    bytes[offset] = UInt8((value >> 24) & 0xFF)
    bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
    bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
    bytes[offset + 3] = UInt8(value & 0xFF)
  }
}

/// FNT-01: why a face cannot be embedded as an editable subset. Each refusal
/// is explicit; the import UI shows the reason and never substitutes a
/// different font.
public enum FontEmbeddingRefusal: Sendable, Equatable {
  /// CFF/OpenType outlines have no editable-subset writer (FNT-03 boundary).
  case cffOutlines
  /// OS/2 fsType embedding rights restrict embedding, or are missing/unknown.
  case restrictedEmbedding
  /// No usable Unicode cmap, so Unicode text cannot be mapped to glyphs.
  case missingUnicodeMap
  /// The program could not be parsed by the bounded inspector.
  case malformedProgram
  /// The existing TrueType subsetter cannot process this program.
  case subsettingFailed
  /// Core Text could not load a preview font for the face.
  case previewUnavailable
  /// A variable font whose default instance could not be verified.
  case variableFontUnverifiable

  public var message: String {
    switch self {
    case .cffOutlines:
      return
        "This face has CFF/OpenType outlines. Inline PDF editing only embeds TrueType outlines, so this face cannot be subset-embedded."
    case .restrictedEmbedding:
      return
        "This font's OS/2 embedding rights do not allow editable subset embedding, or are missing. The app does not override font licensing flags."
    case .missingUnicodeMap:
      return
        "This face has no usable Unicode character map, so its glyphs cannot be matched to the text you type."
    case .malformedProgram:
      return "This face's font program is malformed or unsupported and cannot be embedded."
    case .subsettingFailed:
      return
        "This face cannot be subset by the app's TrueType subsetter, so it cannot be embedded safely."
    case .previewUnavailable:
      return "Core Text could not load this face, so it cannot be previewed or measured."
    case .variableFontUnverifiable:
      return
        "This variable font's default axis values could not be verified. Non-default instances are not supported yet."
    }
  }
}

public enum FontEmbeddingEligibility: Sendable, Equatable {
  case eligible
  case refused(FontEmbeddingRefusal)

  public var isEligible: Bool {
    if case .eligible = self { return true }
    return false
  }

  public var refusal: FontEmbeddingRefusal? {
    if case .refused(let reason) = self { return reason }
    return nil
  }

  /// A one-line label for the import UI.
  public var label: String {
    switch self {
    case .eligible: return "Eligible for subset embedding"
    case .refused(let reason): return reason.message
    }
  }
}

/// FNT-01: the checked properties of one extracted face. The program is the
/// exact bytes that will be subset-embedded if the face is chosen; the digest
/// is the stable identity a license acceptance record is keyed by.
public struct FontFaceInspection: Sendable, Equatable {
  public let faceIndex: Int
  public let sfntVersion: UInt32
  public let program: Data
  public let programDigest: String
  public let glyphCount: Int
  public let unitsPerEm: Int
  public let mappedScalarCount: Int
  public let embeddingFlags: Int?
  public let isVariableFont: Bool
  public let wasExtractedFromCollection: Bool
  public let eligibility: FontEmbeddingEligibility

  public var isEligible: Bool { eligibility.isEligible }

  init(
    faceIndex: Int, sfntVersion: UInt32, program: Data, glyphCount: Int, unitsPerEm: Int,
    mappedScalarCount: Int, embeddingFlags: Int?, isVariableFont: Bool,
    wasExtractedFromCollection: Bool, eligibility: FontEmbeddingEligibility
  ) {
    self.faceIndex = faceIndex
    self.sfntVersion = sfntVersion
    self.program = program
    self.programDigest = FontImportDigest.sha256Hex(program)
    self.glyphCount = glyphCount
    self.unitsPerEm = unitsPerEm
    self.mappedScalarCount = mappedScalarCount
    self.embeddingFlags = embeddingFlags
    self.isVariableFont = isVariableFont
    self.wasExtractedFromCollection = wasExtractedFromCollection
    self.eligibility = eligibility
  }
}

/// FNT-01: face discovery plus embedding-eligibility checks for a
/// user-provided font file. This is the pure, AppKit-free half of the import
/// flow: the MacServices layer adds Core Text names/preview checks, and the app
/// layer collects the license assertion and records the accepted face.
public enum FontImportInspection {
  public struct Limits: Sendable, Equatable {
    public var extraction: FontFaceExtractor.Limits
    /// Prove the existing subsetter can process each font face by running a
    /// small dry-run subset. Off only for tests that inject a broken program.
    public var validateSubsetting: Bool

    public init(
      extraction: FontFaceExtractor.Limits = .init(), validateSubsetting: Bool = true
    ) {
      self.extraction = extraction
      self.validateSubsetting = validateSubsetting
    }
  }

  /// Inspect the data and return one entry per face. Container-level failures
  /// throw; a face whose program is malformed is returned as an explicit
  /// refusal so a collection with one bad member can still offer its good
  /// faces.
  public static func inspectFaces(
    _ data: Data, limits: Limits = .init()
  ) throws -> [FontFaceInspection] {
    let faces = try FontFaceExtractor.extractFaces(from: data, limits: limits.extraction)
    return faces.map { face in
      evaluate(
        program: face.program, faceIndex: face.faceIndex, sfntVersion: face.sfntVersion,
        wasExtractedFromCollection: face.wasExtractedFromCollection,
        validateSubsetting: limits.validateSubsetting)
    }
  }

  /// Inspect one standalone face program. Used to re-verify a stored imported
  /// face before it is offered for writing.
  public static func inspectFace(
    program: Data, faceIndex: Int = 0, sfntVersion: UInt32 = 0x0001_0000,
    wasExtractedFromCollection: Bool = false, validateSubsetting: Bool = true
  ) -> FontFaceInspection {
    evaluate(
      program: program, faceIndex: faceIndex, sfntVersion: sfntVersion,
      wasExtractedFromCollection: wasExtractedFromCollection,
      validateSubsetting: validateSubsetting)
  }

  private static func evaluate(
    program: Data, faceIndex: Int, sfntVersion: UInt32,
    wasExtractedFromCollection: Bool, validateSubsetting: Bool
  ) -> FontFaceInspection {
    func refused(_ reason: FontEmbeddingRefusal, inspector: TrueTypeInspector? = nil)
      -> FontFaceInspection
    {
      FontFaceInspection(
        faceIndex: faceIndex, sfntVersion: sfntVersion, program: program,
        glyphCount: inspector?.glyphCount ?? 0, unitsPerEm: inspector?.unitsPerEm ?? 0,
        mappedScalarCount: inspector?.unicodeToGlyph.count ?? 0,
        embeddingFlags: inspector?.embeddingFlags, isVariableFont: inspector?.tables["fvar"] != nil,
        wasExtractedFromCollection: wasExtractedFromCollection,
        eligibility: .refused(reason))
    }

    let inspector: TrueTypeInspector
    do {
      inspector = try TrueTypeInspector.inspect(program)
    } catch {
      // Distinguish "CFF without a cmap" from an unreadable program so the
      // UI can name the real boundary instead of a generic parse failure.
      guard let tolerant = try? TrueTypeInspector.inspect(program, requireUnicodeMap: false)
      else {
        return refused(.malformedProgram)
      }
      return refused(tolerant.isCFF ? .cffOutlines : .missingUnicodeMap, inspector: tolerant)
    }

    if inspector.isCFF { return refused(.cffOutlines, inspector: inspector) }
    guard inspector.permitsEditableSubsetEmbedding else {
      return refused(.restrictedEmbedding, inspector: inspector)
    }
    let usableGlyphs = inspector.unicodeToGlyph.filter {
      $0.value > 0 && $0.value < inspector.glyphCount
    }
    guard !usableGlyphs.isEmpty else {
      return refused(.missingUnicodeMap, inspector: inspector)
    }
    let eligible = FontFaceInspection(
      faceIndex: faceIndex, sfntVersion: sfntVersion, program: program,
      glyphCount: inspector.glyphCount, unitsPerEm: inspector.unitsPerEm,
      mappedScalarCount: inspector.unicodeToGlyph.count,
      embeddingFlags: inspector.embeddingFlags, isVariableFont: inspector.tables["fvar"] != nil,
      wasExtractedFromCollection: wasExtractedFromCollection, eligibility: .eligible)
    guard validateSubsetting else { return eligible }
    guard canSubset(program: program, inspector: inspector, mapped: usableGlyphs) else {
      return refused(.subsettingFailed, inspector: inspector)
    }
    return eligible
  }

  /// FNT-01: prove the chosen face can actually be subset-embedded by running
  /// a small dry-run pass through the same subsetter the writer uses, and by
  /// checking the subset preserves the sampled glyph identities and advances.
  private static func canSubset(
    program: Data, inspector: TrueTypeInspector, mapped: [Int: Int]
  ) -> Bool {
    var samples: [Int] = []
    for preferred in [0x41, 0x20, 0x30, 0x61] where mapped[preferred] != nil {
      samples.append(preferred)
    }
    for scalar in mapped.keys.sorted() where samples.count < 6 && !samples.contains(scalar) {
      samples.append(scalar)
    }
    guard !samples.isEmpty else { return false }
    guard let subset = try? TrueTypeSubsetter.subset(program: program, unicodes: Set(samples)),
      let sub = try? TrueTypeInspector.inspect(subset)
    else { return false }
    for scalar in samples {
      guard let sourceGlyph = mapped[scalar],
        let subsetGlyph = sub.unicodeToGlyph[scalar],
        subsetGlyph > 0, subsetGlyph < sub.glyphCount
      else { return false }
      guard inspector.advances[sourceGlyph] == sub.advances[subsetGlyph] else { return false }
    }
    return true
  }
}
