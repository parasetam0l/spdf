import CommonCrypto
import CryptoKit
import Foundation

// MARK: - Cipher primitives

/// P28-003/P28-004: public system primitives only, separated from PDF key
/// derivation and object-key rules. Hashes come from CryptoKit
/// (`Insecure.MD5`, SHA-256/384/512). AES in CBC mode without padding comes
/// from CommonCrypto's `CCCrypt`, the only public system entry point for raw
/// CBC mode; a single 16-byte block with a zero IV is AES-ECB, which the
/// /Perms validation needs. CryptoKit exposes no RC4 and CommonCrypto's RC4
/// is deprecated, so RC4 is implemented first-party and verified against the
/// RFC 6229 vectors.
enum PDFCipher {
  static func md5(_ data: Data) -> Data {
    Data(Insecure.MD5.hash(data: data))
  }

  static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
  static func sha384(_ data: Data) -> Data { Data(SHA384.hash(data: data)) }
  static func sha512(_ data: Data) -> Data { Data(SHA512.hash(data: data)) }

  /// RC4 (symmetric, so one function serves both directions).
  static func rc4(key: Data, data: Data) -> Data {
    let keyBytes = [UInt8](key)
    guard !keyBytes.isEmpty else { return data }
    var state = [UInt8](0...255)
    var j = 0
    for i in 0..<256 {
      j = (j + Int(state[i]) + Int(keyBytes[i % keyBytes.count])) & 0xFF
      state.swapAt(i, j)
    }
    var output = [UInt8](repeating: 0, count: data.count)
    var i = 0
    j = 0
    for (index, byte) in data.enumerated() {
      i = (i + 1) & 0xFF
      j = (j + Int(state[i])) & 0xFF
      state.swapAt(i, j)
      let k = state[(Int(state[i]) + Int(state[j])) & 0xFF]
      output[index] = byte ^ k
    }
    return Data(output)
  }

  /// AES in CBC mode without padding. The input must be a whole number of
  /// 16-byte blocks; `encrypt` is false for decryption.
  static func aesCBC(key: Data, iv: Data, data: Data, encrypt: Bool) throws -> Data {
    guard key.count == 16 || key.count == 24 || key.count == 32, iv.count == 16 else {
      throw PDFError(.unsupported, "Unsupported AES key or IV size")
    }
    guard !data.isEmpty, data.count % 16 == 0 else {
      throw PDFError(.malformed, "AES data is not a whole number of blocks")
    }
    var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
    var moved = 0
    let status = data.withUnsafeBytes { input in
      key.withUnsafeBytes { keyBuffer in
        iv.withUnsafeBytes { ivBuffer in
          CCCrypt(
            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
            keyBuffer.baseAddress, key.count, ivBuffer.baseAddress,
            input.baseAddress, data.count, &output, output.count, &moved)
        }
      }
    }
    guard status == kCCSuccess else {
      throw PDFError(.malformed, "AES operation failed")
    }
    return Data(output.prefix(moved))
  }
}

// MARK: - Encryption dictionary inventory

/// P28-001: the standard security handler inventory: version and revision,
/// key length, permission flags, crypt filters, and the password entries.
/// The dictionary itself is never encrypted, so this inventory is available
/// before any password is known.
public struct PDFEncryptionInfo: Sendable, Equatable {
  /// P28-002: each supported profile maps to one exact normative algorithm
  /// set; anything else is refused instead of guessed.
  public enum Profile: String, Sendable, Equatable {
    /// V1/R2: 40-bit RC4 (ISO 32000-2 Algorithms 2, 6, 1).
    case rc4_40
    /// V2/R3: 40–128-bit RC4.
    case rc4_128
    /// V4/R4 with /CFM /AESV2: AES-128 (Algorithm 1 with the sAlT suffix).
    case aes128
    /// V5/R5: AES-256 with the deprecated single-hash derivation.
    case aes256Revision5
    /// V5/R6: AES-256 with Algorithm 2.B (PDF 2.0).
    case aes256
  }

  public struct CryptFilter: Sendable, Equatable {
    public enum Method: String, Sendable, Equatable {
      case none = "None"
      case rc4 = "V2"
      case aes128 = "AESV2"
      case aes256 = "AESV3"
    }
    public let method: Method
  }

  public let profile: Profile
  public let version: Int
  public let revision: Int
  public let keyLengthBytes: Int
  public let permissions: Int32
  public let encryptMetadata: Bool
  public let owner: Data
  public let user: Data
  public let ownerEncrypted: Data?
  public let userEncrypted: Data?
  public let perms: Data?
  public let fileID: Data
  public let cryptFilters: [String: CryptFilter]
  public let streamFilterName: String
  public let stringFilterName: String
  public let embeddedFileFilterName: String?

  /// Table 22 permission bits (1-based bit positions).
  public var allowsPrinting: Bool { permissions & 4 != 0 }
  public var allowsModification: Bool { permissions & 8 != 0 }
  public var allowsCopying: Bool { permissions & 16 != 0 }
  public var allowsAnnotation: Bool { permissions & 32 != 0 }
  public var allowsFormFilling: Bool { permissions & 256 != 0 }
  public var allowsExtraction: Bool { permissions & 512 != 0 }
  public var allowsAssembly: Bool { permissions & 1024 != 0 }
  public var allowsHighQualityPrinting: Bool { permissions & 2048 != 0 }
}

extension PDFEncryptionInfo {
  static func nameString(_ name: PDFName) -> String {
    String(decoding: name.bytes, as: UTF8.self)
  }

  /// P28-001: parse and validate the inventory from the trailer's /Encrypt
  /// dictionary. `resolve` loads referenced objects on demand (the dictionary
  /// and its entries are never encrypted).
  static func parse(
    trailer: [PDFName: PDFValue],
    resolve: (PDFObjectID) throws -> PDFValue?
  ) throws -> PDFEncryptionInfo {
    func resolved(_ value: PDFValue?) -> PDFValue? {
      guard let value else { return nil }
      if case .reference(let id) = value { return try? resolve(id) }
      return value
    }
    func dictionary(_ value: PDFValue?) throws -> [PDFName: PDFValue] {
      guard case .dictionary(let dict)? = resolved(value) else {
        throw PDFError(.malformed, "The encryption dictionary is missing or malformed")
      }
      return dict
    }
    func integer(_ value: PDFValue?) -> Int? {
      guard case .integer(let raw)? = resolved(value), let int = Int(exactly: raw) else {
        return nil
      }
      return int
    }
    func data(_ value: PDFValue?) -> Data? {
      guard case .string(let data)? = resolved(value) else { return nil }
      return data
    }
    func name(_ value: PDFValue?) -> String? {
      guard case .name(let name)? = resolved(value) else { return nil }
      return nameString(name)
    }

    guard let encryptValue = trailer[PDFName("Encrypt")] else {
      throw PDFError(.malformed, "The trailer has no encryption dictionary")
    }
    let encryptDictionary = try dictionary(encryptValue)

    // P28-015: public-key handlers are refused explicitly.
    if let filter = name(encryptDictionary[PDFName("Filter")]), filter != "Standard" {
      throw PDFError(
        .unsupported,
        "The \(filter) security handler is not supported; only the standard handler is")
    }
    guard let version = integer(encryptDictionary[PDFName("V")]),
      let revision = integer(encryptDictionary[PDFName("R")])
    else {
      throw PDFError(.malformed, "The encryption dictionary has no V or R entry")
    }
    guard let owner = data(encryptDictionary[PDFName("O")]),
      let user = data(encryptDictionary[PDFName("U")])
    else {
      throw PDFError(.malformed, "The encryption dictionary has no O or U entry")
    }
    let permissions = Int32(truncatingIfNeeded: integer(encryptDictionary[PDFName("P")]) ?? 0)
    let encryptMetadata: Bool
    switch resolved(encryptDictionary[PDFName("EncryptMetadata")]) {
    case .boolean(let flag)?: encryptMetadata = flag
    case .integer(let raw)?: encryptMetadata = raw != 0
    default: encryptMetadata = true
    }

    // File identifier: the first element of the trailer's /ID array.
    var fileID = Data()
    if case .array(let ids)? = trailer[PDFName("ID")], case .string(let first)? = ids.first {
      fileID = first
    }

    var cryptFilters: [String: CryptFilter] = [:]
    if let cf = try? dictionary(encryptDictionary[PDFName("CF")]) {
      for (filterName, value) in cf {
        guard case .dictionary(let entry)? = resolved(value) else { continue }
        guard let methodName = name(entry[PDFName("CFM")]),
          let method = CryptFilter.Method(rawValue: methodName)
        else {
          throw PDFError(
            .unsupported,
            "A crypt filter method other than None, V2, AESV2, or AESV3 is not supported")
        }
        cryptFilters[nameString(filterName)] = CryptFilter(method: method)
      }
    }
    let streamFilterName = name(encryptDictionary[PDFName("StmF")]) ?? "Identity"
    let stringFilterName = name(encryptDictionary[PDFName("StrF")]) ?? "Identity"
    let embeddedFileFilterName = name(encryptDictionary[PDFName("EFF")])

    func method(named name: String) throws -> CryptFilter.Method {
      if name == "Identity" { return .none }
      guard let filter = cryptFilters[name] else {
        throw PDFError(.unsupported, "The \(name) crypt filter is not declared")
      }
      return filter.method
    }

    let keyLengthBits = integer(encryptDictionary[PDFName("Length")]) ?? 40
    let profile: Profile
    var keyLengthBytes = max(5, min(16, keyLengthBits / 8))
    switch (version, revision) {
    case (1, 2):
      profile = .rc4_40
      keyLengthBytes = 5
    case (2, 3):
      guard keyLengthBits % 8 == 0, (40...128).contains(keyLengthBits) else {
        throw PDFError(.unsupported, "An unsupported RC4 key length was requested")
      }
      profile = .rc4_128
      keyLengthBytes = keyLengthBits / 8
    case (4, 4):
      let streamMethod = try method(named: streamFilterName)
      switch streamMethod {
      case .rc4:
        profile = .rc4_128
        keyLengthBytes = 16
      case .aes128:
        profile = .aes128
        keyLengthBytes = 16
      case .none:
        throw PDFError(
          .unsupported, "An identity-only crypt filter set is not a supported encryption profile")
      case .aes256:
        throw PDFError(.unsupported, "AESV3 requires V5")
      }
    case (5, 5), (5, 6):
      guard owner.count == 48, user.count == 48 else {
        throw PDFError(.unsupported, "AES-256 encryption requires 48-byte O and U entries")
      }
      guard data(encryptDictionary[PDFName("OE")]) != nil, data(encryptDictionary[PDFName("UE")]) != nil,
        data(encryptDictionary[PDFName("Perms")]) != nil
      else {
        throw PDFError(.malformed, "AES-256 encryption requires OE, UE, and Perms entries")
      }
      let streamMethod = try method(named: streamFilterName)
      // Producers occasionally write AESV2 with V5; the reference behavior is
      // to use AES-256 anyway.
      guard streamMethod == .aes256 || (version == 5 && streamMethod == .aes128) else {
        throw PDFError(.unsupported, "V5 encryption requires the AESV3 crypt filter")
      }
      profile = revision == 5 ? .aes256Revision5 : .aes256
      keyLengthBytes = 32
    default:
      throw PDFError(
        .unsupported, "Encryption V\(version) R\(revision) is not supported")
    }

    return PDFEncryptionInfo(
      profile: profile, version: version, revision: revision, keyLengthBytes: keyLengthBytes,
      permissions: permissions, encryptMetadata: encryptMetadata, owner: owner, user: user,
      ownerEncrypted: data(encryptDictionary[PDFName("OE")]), userEncrypted: data(encryptDictionary[PDFName("UE")]),
      perms: data(encryptDictionary[PDFName("Perms")]), fileID: fileID, cryptFilters: cryptFilters,
      streamFilterName: streamFilterName, stringFilterName: stringFilterName,
      embeddedFileFilterName: embeddedFileFilterName)
  }
}

// MARK: - Password algorithms

/// P28-002/P28-004: PDF key derivation and password validation per the
/// normative algorithms, on top of the primitive layer. Nothing here logs or
/// stores credentials; candidates are derived, compared, and released.
struct PDFStandardSecurity {
  let info: PDFEncryptionInfo

  static let passwordPadding: [UInt8] = [
    0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA,
    0x01, 0x08, 0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE,
    0x64, 0x53, 0x69, 0x7A,
  ]

  /// P28-006/P28-007: authenticate a user or owner password and return the
  /// file encryption key. nil means the password does not match; unsupported
  /// profiles never reach this call.
  func authenticate(password: String) throws -> (key: Data, isOwner: Bool)? {
    switch info.profile {
    case .rc4_40, .rc4_128, .aes128:
      return legacyAuthenticate(password: password)
    case .aes256Revision5, .aes256:
      return try modernAuthenticate(password: password)
    }
  }

  // MARK: Revision 4 and earlier

  /// R2–R4 candidate bytes: PDFDocEncoding is Latin-1-like for practical
  /// passwords, so UTF-8 and Latin-1 are both tried.
  private func legacyCandidates(_ password: String) -> [Data] {
    var candidates: [Data] = []
    if let utf8 = password.data(using: .utf8) { candidates.append(utf8) }
    if let latin = password.data(using: .isoLatin1), latin != candidates.first {
      candidates.append(latin)
    }
    return candidates
  }

  static func paddedPassword(_ password: [UInt8]) -> [UInt8] {
    var padded = Array(password.prefix(32))
    var index = 0
    while padded.count < 32 {
      padded.append(passwordPadding[index])
      index += 1
    }
    return padded
  }

  private func legacyAuthenticate(password: String) -> (key: Data, isOwner: Bool)? {
    for candidate in legacyCandidates(password) {
      if let key = legacyUserKey(padded: Self.paddedPassword(Array(candidate))) {
        return (key, false)
      }
    }
    for candidate in legacyCandidates(password) {
      guard let userPadded = legacyRecoverUserPassword(ownerPassword: Array(candidate)) else {
        continue
      }
      if let key = legacyUserKey(padded: userPadded) {
        return (key, true)
      }
    }
    return nil
  }

  /// Algorithm 2 with the /U verification of Algorithm 6.
  private func legacyUserKey(padded: [UInt8]) -> Data? {
    guard padded.count == 32 else { return nil }
    var input = Data(padded)
    input.append(info.owner)
    input.append(contentsOf: Self.littleEndian32(info.permissions))
    input.append(info.fileID)
    if info.revision >= 4 && !info.encryptMetadata {
      input.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
    }
    var hash = PDFCipher.md5(input)
    if info.revision >= 3 {
      for _ in 0..<50 {
        hash = PDFCipher.md5(Data(hash.prefix(info.keyLengthBytes)))
      }
    }
    let key = Data(hash.prefix(info.keyLengthBytes))

    let check: Data
    if info.revision == 2 {
      check = PDFCipher.rc4(key: key, data: Data(Self.passwordPadding))
    } else {
      var seed = Data(Self.passwordPadding)
      seed.append(info.fileID)
      var value = PDFCipher.rc4(key: key, data: PDFCipher.md5(seed))
      for round in 1...19 {
        let derived = Data(key.map { $0 ^ UInt8(round) })
        value = PDFCipher.rc4(key: derived, data: value)
      }
      check = value
    }
    let compareLength = info.revision == 2 ? 32 : 16
    guard check.prefix(compareLength) == info.user.prefix(compareLength) else { return nil }
    return key
  }

  /// Algorithm 7: recover the padded user password from the owner password.
  private func legacyRecoverUserPassword(ownerPassword: [UInt8]) -> [UInt8]? {
    let padded = Self.paddedPassword(ownerPassword)
    var hash = PDFCipher.md5(Data(padded))
    if info.revision >= 3 {
      for _ in 0..<50 {
        hash = PDFCipher.md5(Data(hash.prefix(info.keyLengthBytes)))
      }
    }
    let key = Data(hash.prefix(info.keyLengthBytes))
    var value = info.owner
    if info.revision == 2 {
      value = PDFCipher.rc4(key: key, data: value)
    } else {
      for round in stride(from: 19, through: 0, by: -1) {
        let derived = Data(key.map { $0 ^ UInt8(round) })
        value = PDFCipher.rc4(key: derived, data: value)
      }
    }
    guard value.count >= 32 else { return nil }
    return Array(value.prefix(32))
  }

  static func littleEndian32(_ value: Int32) -> [UInt8] {
    let raw = UInt32(bitPattern: value)
    return [
      UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF), UInt8((raw >> 16) & 0xFF),
      UInt8((raw >> 24) & 0xFF),
    ]
  }

  // MARK: Revision 5 and 6

  /// P28-014: revision 6 passwords are UTF-8 truncated to 127 bytes. The
  /// reference implementations first try the SASLprep-mapped form and then
  /// the raw form, because producers differ; revision 5 uses the raw UTF-8
  /// form. Every candidate must still pass PDF password verification.
  static func modernPasswordCandidates(_ password: String, revision: Int) -> [String] {
    guard revision >= 6 else { return [password] }
    let prepped = saslPrep(password)
    return prepped == password ? [password] : [prepped, password]
  }

  /// RFC 4013 mapping (table C.1.2 to space, table B.1 to nothing) followed by
  /// NFKC. The prohibited-output and bidirectional checks are intentionally
  /// omitted, matching the reference implementations: a candidate must still
  /// pass PDF password verification.
  static func saslPrep(_ password: String) -> String {
    var mapped = String.UnicodeScalarView()
    for scalar in password.unicodeScalars {
      switch scalar.value {
      case 0x00A0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000:
        mapped.append(" ")
      case 0x00AD, 0x034F, 0x1806, 0x180B...0x180D, 0x200B...0x200D, 0x2060,
        0xFE00...0xFE0F, 0xFEFF:
        continue
      default:
        mapped.append(scalar)
      }
    }
    return String(mapped).precomposedStringWithCompatibilityMapping
  }

  private func modernAuthenticate(password: String) throws -> (key: Data, isOwner: Bool)? {
    let user = [UInt8](info.user)
    let owner = [UInt8](info.owner)
    guard user.count >= 48, owner.count >= 48 else { return nil }
    let userValidationSalt = Data(user[32..<40])
    let userKeySalt = Data(user[40..<48])
    let ownerValidationSalt = Data(owner[32..<40])
    let ownerKeySalt = Data(owner[40..<48])
    let user48 = Data(user[0..<48])
    let zeroIV = Data(repeating: 0, count: 16)

    for candidate in Self.modernPasswordCandidates(password, revision: info.revision) {
      let bytes = Array(candidate.utf8.prefix(127))
      let userHash = try modernHash(password: bytes, salt: userValidationSalt, userBytes: Data())
      if userHash == Data(user[0..<32]) {
        let intermediate = try modernHash(password: bytes, salt: userKeySalt, userBytes: Data())
        guard let ue = info.userEncrypted, ue.count == 32 else { return nil }
        let key = try PDFCipher.aesCBC(key: intermediate, iv: zeroIV, data: ue, encrypt: false)
        guard key.count == 32 else { return nil }
        return (key, false)
      }
      guard !bytes.isEmpty else { continue }
      let ownerHash = try modernHash(
        password: bytes, salt: ownerValidationSalt, userBytes: user48)
      if ownerHash == Data(owner[0..<32]) {
        let intermediate = try modernHash(
          password: bytes, salt: ownerKeySalt, userBytes: user48)
        guard let oe = info.ownerEncrypted, oe.count == 32 else { return nil }
        let key = try PDFCipher.aesCBC(key: intermediate, iv: zeroIV, data: oe, encrypt: false)
        guard key.count == 32 else { return nil }
        return (key, true)
      }
    }
    return nil
  }

  /// Algorithm 2.B: the revision 6 hash (revision 5 is a single SHA-256).
  func modernHash(password: [UInt8], salt: Data, userBytes: Data) throws -> Data {
    try Self.revisionHash(
      password: password, salt: salt, userBytes: userBytes, revision: info.revision)
  }

  /// Algorithm 2.B for a given revision, usable by both the reader and the
  /// encrypted writer.
  static func revisionHash(password: [UInt8], salt: Data, userBytes: Data, revision: Int) throws
    -> Data
  {
    var input = Data(password)
    input.append(salt)
    input.append(userBytes)
    var k = PDFCipher.sha256(input)
    guard revision >= 6 else { return k }
    var e = Data([0])
    var round = 0
    while round < 64 || Int(e.last ?? 0) > round - 32 {
      var combined = Data(password)
      combined.append(k)
      combined.append(userBytes)
      var k1 = Data()
      k1.reserveCapacity(combined.count * 64)
      for _ in 0..<64 { k1.append(combined) }
      e = try PDFCipher.aesCBC(
        key: Data(k.prefix(16)), iv: Data(k.dropFirst(16).prefix(16)), data: k1, encrypt: true)
      let remainder = e.prefix(16).reduce(0) { ($0 + Int($1)) % 3 }
      switch remainder {
      case 0: k = PDFCipher.sha256(e)
      case 1: k = PDFCipher.sha384(e)
      default: k = PDFCipher.sha512(e)
      }
      round += 1
    }
    return Data(k.prefix(32))
  }

  /// Algorithm 13: validate the /Perms entry against the file key. A failure
  /// is reported but does not block reading (producers get this wrong).
  func validatePerms(fileKey: Data) -> Bool {
    guard let perms = info.perms, perms.count == 16 else { return false }
    guard
      let decrypted = try? PDFCipher.aesCBC(
        key: fileKey, iv: Data(repeating: 0, count: 16), data: perms, encrypt: false),
      decrypted.count == 16
    else { return false }
    let bytes = [UInt8](decrypted)
    guard bytes[9] == 0x61, bytes[10] == 0x64, bytes[11] == 0x62 else { return false }
    let p = Int32(bytes[0]) | Int32(bytes[1]) << 8 | Int32(bytes[2]) << 16 | Int32(bytes[3]) << 24
    let metadata = bytes[8] == 0x54
    return p == info.permissions && metadata == info.encryptMetadata
  }
}

// MARK: - Object decryption

/// P28-004/P28-009/P28-010/P28-013: object-level decryption on top of an
/// authenticated file key. Object keys follow Algorithm 1 for revisions 4 and
/// earlier; revisions 5 and 6 use the file key directly. Crypt-filter
/// selection honors StmF, StrF, EFF, explicit /Crypt filter parameters, the
/// /EncryptMetadata flag, and the structures that are never encrypted.
struct PDFDecryptionContext: Sendable {
  let info: PDFEncryptionInfo
  var fileKey: Data
  let isOwner: Bool

  /// P04-025: best-effort clearing of the file key. Swift value semantics
  /// cannot guarantee every copy is wiped (the compiler and crypto routines
  /// copy freely), so this zeroes the bytes owned here and callers drop
  /// their references; it is hygiene, not a memory-safety proof.
  public mutating func reset() {
    fileKey.resetBytes(in: 0..<fileKey.count)
  }

  /// Algorithm 1: the object key mixes the object and generation numbers;
  /// AES adds the sAlT suffix.
  func objectKey(for id: PDFObjectID, aes: Bool) -> Data {
    switch info.profile {
    case .aes256Revision5, .aes256:
      return fileKey
    default:
      var input = fileKey
      let number = id.number
      input.append(contentsOf: [
        UInt8(number & 0xFF), UInt8((number >> 8) & 0xFF), UInt8((number >> 16) & 0xFF),
      ])
      input.append(contentsOf: [UInt8(id.generation & 0xFF), UInt8((id.generation >> 8) & 0xFF)])
      if aes { input.append(contentsOf: Array("sAlT".utf8)) }
      let digest = PDFCipher.md5(input)
      return Data(digest.prefix(min(fileKey.count + 5, 16)))
    }
  }

  func method(named name: String) throws -> PDFEncryptionInfo.CryptFilter.Method {
    if name == "Identity" { return .none }
    guard let filter = info.cryptFilters[name] else {
      throw PDFError(.unsupported, "The \(name) crypt filter is not declared")
    }
    return filter.method
  }

  /// P28-010/P28-011/P28-012: resolve the crypt filter for a stream.
  func streamMethod(for dictionary: [PDFName: PDFValue]) throws -> PDFEncryptionInfo.CryptFilter
    .Method
  {
    if let explicit = Self.explicitCryptFilter(in: dictionary) {
      return try method(named: explicit)
    }
    if !info.encryptMetadata, dictionary[PDFName("Type")] == .name(PDFName("Metadata")) {
      return .none
    }
    if dictionary[PDFName("Type")] == .name(PDFName("EmbeddedFile")),
      let embedded = info.embeddedFileFilterName
    {
      return try method(named: embedded)
    }
    switch info.profile {
    case .rc4_40, .rc4_128:
      return .rc4
    default:
      return try method(named: info.streamFilterName)
    }
  }

  func stringMethod() throws -> PDFEncryptionInfo.CryptFilter.Method {
    switch info.profile {
    case .rc4_40, .rc4_128:
      return .rc4
    default:
      return try method(named: info.stringFilterName)
    }
  }

  /// An explicit `/Crypt` filter parameter overrides the default filter.
  static func explicitCryptFilter(in dictionary: [PDFName: PDFValue]) -> String? {
    func name(in value: PDFValue?) -> String? {
      guard case .dictionary(let dict)? = value,
        case .name(let filter)? = dict[PDFName("Name")]
      else { return nil }
      return String(decoding: filter.bytes, as: UTF8.self)
    }
    if let direct = name(in: dictionary[PDFName("DecodeParms")]) { return direct }
    if case .array(let filters)? = dictionary[PDFName("Filter")],
      case .array(let parms)? = dictionary[PDFName("DecodeParms")]
    {
      for (index, filter) in filters.enumerated() {
        guard case .name(let filterName) = filter,
          String(decoding: filterName.bytes, as: UTF8.self) == "Crypt",
          index < parms.count
        else { continue }
        return name(in: parms[index])
      }
    }
    return nil
  }

  func decrypt(_ data: Data, method: PDFEncryptionInfo.CryptFilter.Method, id: PDFObjectID)
    throws -> Data
  {
    switch method {
    case .none:
      return data
    case .rc4:
      return PDFCipher.rc4(key: objectKey(for: id, aes: false), data: data)
    case .aes128:
      return try aesDecrypt(data, key: objectKey(for: id, aes: true))
    case .aes256:
      return try aesDecrypt(data, key: fileKey)
    }
  }

  private func aesDecrypt(_ data: Data, key: Data) throws -> Data {
    guard data.count >= 16, data.count % 16 == 0 else {
      throw PDFError(.malformed, "Encrypted AES data is not a whole number of blocks")
    }
    let iv = data.prefix(16)
    let ciphertext = data.dropFirst(16)
    let decrypted = try PDFCipher.aesCBC(
      key: key, iv: Data(iv), data: Data(ciphertext), encrypt: false)
    // 7.6.3.2: encrypted data is padded to a block multiple; the final byte
    // holds the pad count (1...16) and the pad bytes all equal it.
    let bytes = [UInt8](decrypted)
    if let last = bytes.last, (1...16).contains(last), bytes.count >= Int(last) {
      let pad = Int(last)
      if bytes.suffix(pad).allSatisfy({ $0 == last }) {
        return Data(bytes.prefix(bytes.count - pad))
      }
    }
    return decrypted
  }

  func decryptStringData(_ data: Data, id: PDFObjectID) throws -> Data {
    let method = try stringMethod()
    return try decrypt(data, method: method, id: id)
  }

  func decryptStreamData(_ data: Data, id: PDFObjectID, dictionary: [PDFName: PDFValue]) throws
    -> Data
  {
    let method = try streamMethod(for: dictionary)
    return try decrypt(data, method: method, id: id)
  }

  /// P28-012: decrypt every string and stream in one object, skipping the
  /// structures that are never encrypted: cross-reference streams, signature
  /// /Contents values, and the encryption dictionary itself (the loader skips
  /// that object entirely).
  func decryptObject(_ value: PDFValue, id: PDFObjectID) throws -> PDFValue {
    if case .stream(let stream) = value,
      stream.dictionary[PDFName("Type")] == .name(PDFName("XRef"))
    {
      return value
    }
    return try decryptValue(value, id: id)
  }

  /// P28-020: the symmetric direction. Encryption shares the method
  /// resolution with decryption; AES writes a fresh random IV prefix and
  /// 7.6.3.2 padding, RC4 is its own inverse.
  func encrypt(_ data: Data, method: PDFEncryptionInfo.CryptFilter.Method, id: PDFObjectID)
    throws -> Data
  {
    switch method {
    case .none:
      return data
    case .rc4:
      return PDFCipher.rc4(key: objectKey(for: id, aes: false), data: data)
    case .aes128:
      return try aesEncrypt(data, key: objectKey(for: id, aes: true))
    case .aes256:
      return try aesEncrypt(data, key: fileKey)
    }
  }

  private func aesEncrypt(_ data: Data, key: Data) throws -> Data {
    var padded = data
    let pad = 16 - (data.count % 16)
    padded.append(contentsOf: [UInt8](repeating: UInt8(pad), count: pad))
    let iv = PDFEncryptionOutput.randomBytes(16)
    let ciphertext = try PDFCipher.aesCBC(key: key, iv: iv, data: padded, encrypt: true)
    var output = iv
    output.append(ciphertext)
    return output
  }

  func encryptStringData(_ data: Data, id: PDFObjectID) throws -> Data {
    let method = try stringMethod()
    return try encrypt(data, method: method, id: id)
  }

  func encryptStreamData(_ data: Data, id: PDFObjectID, dictionary: [PDFName: PDFValue]) throws
    -> Data
  {
    let method = try streamMethod(for: dictionary)
    return try encrypt(data, method: method, id: id)
  }

  /// Encrypt every string and stream in one object with the same exclusions
  /// the reader applies (signature /Contents, unencrypted stream kinds).
  func encryptObject(_ value: PDFValue, id: PDFObjectID) throws -> PDFValue {
    try encryptValue(value, id: id)
  }

  private func decryptValue(_ value: PDFValue, id: PDFObjectID, skipStrings: Bool = false) throws
    -> PDFValue
  {
    switch value {
    case .string(let data):
      return skipStrings ? value : .string(try decryptStringData(data, id: id))
    case .array(let values):
      return .array(try values.map { try decryptValue($0, id: id, skipStrings: skipStrings) })
    case .dictionary(let dictionary):
      let isSignature = dictionary[PDFName("ByteRange")] != nil
      var result: [PDFName: PDFValue] = [:]
      for (key, entry) in dictionary {
        let skip = isSignature && key == PDFName("Contents")
        result[key] = try decryptValue(entry, id: id, skipStrings: skip)
      }
      return .dictionary(result)
    case .stream(let stream):
      // P28-011/P28-026: a stream declared unencrypted (metadata flag or EFF
      // identity) travels whole, dictionary strings included, matching the
      // writer's rule.
      if try streamMethod(for: stream.dictionary) == .none {
        return value
      }
      var stream = stream
      let decrypted = try decryptStreamData(
        stream.bytes, id: id, dictionary: stream.dictionary)
      stream.bytes = decrypted
      // /Length describes the encrypted payload in the file; the graph
      // carries the decrypted payload, so it is normalized like a recovered
      // stream length.
      if case .dictionary(let decryptedDictionary) = try decryptValue(
        .dictionary(stream.dictionary), id: id)
      {
        stream.dictionary = decryptedDictionary
      }
      stream.dictionary[PDFName("Length")] = .integer(Int64(decrypted.count))
      return .stream(stream)
    default:
      return value
    }
  }

  private func encryptValue(_ value: PDFValue, id: PDFObjectID, skipStrings: Bool = false) throws
    -> PDFValue
  {
    switch value {
    case .string(let data):
      return skipStrings ? value : .string(try encryptStringData(data, id: id))
    case .array(let values):
      return .array(try values.map { try encryptValue($0, id: id, skipStrings: skipStrings) })
    case .dictionary(let dictionary):
      let isSignature = dictionary[PDFName("ByteRange")] != nil
      var result: [PDFName: PDFValue] = [:]
      for (key, entry) in dictionary {
        let skip = isSignature && key == PDFName("Contents")
        result[key] = try encryptValue(entry, id: id, skipStrings: skip)
      }
      return .dictionary(result)
    case .stream(let stream):
      if try streamMethod(for: stream.dictionary) == .none {
        return value
      }
      var stream = stream
      let encrypted = try encryptStreamData(
        stream.bytes, id: id, dictionary: stream.dictionary)
      stream.bytes = encrypted
      if case .dictionary(let encryptedDictionary) = try encryptValue(
        .dictionary(stream.dictionary), id: id)
      {
        stream.dictionary = encryptedDictionary
      }
      stream.dictionary[PDFName("Length")] = .integer(Int64(encrypted.count))
      return .stream(stream)
    default:
      return value
    }
  }
}

// MARK: - Encrypted writing

/// P28-016/P28-017: options for supported encrypted output. Only AES-256
/// (V5/R6) is produced; there is deliberately no option to write RC4 or
/// other weak profiles. Permissions are normalized to the reserved-bit rules
/// of Table 22.
public struct PDFEncryptionOptions: Sendable, Equatable {
  public let userPassword: String
  /// Falls back to the user password when nil or empty, per the standard.
  public let ownerPassword: String?
  public let permissions: Int32
  public let encryptMetadata: Bool
  /// P28-026: when true, embedded file streams stay unencrypted and /EFF is
  /// written as /Identity.
  public let unencryptedEmbeddedFiles: Bool

  public init(
    userPassword: String, ownerPassword: String? = nil, permissions: Int32 = -4,
    encryptMetadata: Bool = true, unencryptedEmbeddedFiles: Bool = false
  ) {
    self.userPassword = userPassword
    self.ownerPassword = ownerPassword
    self.permissions = permissions
    self.encryptMetadata = encryptMetadata
    self.unencryptedEmbeddedFiles = unencryptedEmbeddedFiles
  }

  /// Table 22: bits 1–2 are 0, bits 7–8 are 1, bits 13–32 are 1.
  public var normalizedPermissions: Int32 {
    (permissions | Int32(bitPattern: 0xFFFF_F0C0)) & ~Int32(3)
  }
}

/// The encryption state for one output file: file key, dictionary, and the
/// value transform applied to every object. The transform delegates to the
/// reader's context, because the ciphers are symmetric and method resolution
/// (crypt filters, metadata, embedded files) is shared.
struct PDFEncryptionOutput {
  let options: PDFEncryptionOptions
  let fileKey: Data
  let encryptDictionary: [PDFName: PDFValue]
  let fileID: Data
  let context: PDFDecryptionContext

  static func randomBytes(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
  }

  static func make(options: PDFEncryptionOptions) throws -> PDFEncryptionOutput {
    let zeroIV = Data(repeating: 0, count: 16)
    let fileKey = randomBytes(32)
    let userBytes = Array(options.userPassword.utf8.prefix(127))
    let ownerPassword = (options.ownerPassword?.isEmpty == false)
      ? options.ownerPassword! : options.userPassword
    let ownerBytes = Array(ownerPassword.utf8.prefix(127))

    let userValidationSalt = randomBytes(8)
    let userKeySalt = randomBytes(8)
    let ownerValidationSalt = randomBytes(8)
    let ownerKeySalt = randomBytes(8)

    // Algorithm 8: U = hash(password, userValidationSalt, []) + salts;
    // UE = AES-256-CBC(hash(password, userKeySalt, []), zero IV, file key).
    let userHash = try PDFStandardSecurity.revisionHash(
      password: userBytes, salt: userValidationSalt, userBytes: Data(), revision: 6)
    var user = userHash
    user.append(userValidationSalt)
    user.append(userKeySalt)
    let userKey = try PDFStandardSecurity.revisionHash(
      password: userBytes, salt: userKeySalt, userBytes: Data(), revision: 6)
    let userEncrypted = try PDFCipher.aesCBC(
      key: userKey, iv: zeroIV, data: fileKey, encrypt: true)

    // Algorithm 9: O = hash(owner, ownerValidationSalt, U) + salts;
    // OE = AES-256-CBC(hash(owner, ownerKeySalt, U), zero IV, file key).
    let ownerHash = try PDFStandardSecurity.revisionHash(
      password: ownerBytes, salt: ownerValidationSalt, userBytes: user, revision: 6)
    var owner = ownerHash
    owner.append(ownerValidationSalt)
    owner.append(ownerKeySalt)
    let ownerKey = try PDFStandardSecurity.revisionHash(
      password: ownerBytes, salt: ownerKeySalt, userBytes: user, revision: 6)
    let ownerEncrypted = try PDFCipher.aesCBC(
      key: ownerKey, iv: zeroIV, data: fileKey, encrypt: true)

    // Algorithm 10: /Perms = AES-256-ECB(P(4 LE) + FFFFFFFF + 'T'/'F' + adb +
    // random) with the file key.
    var perms = Data(PDFStandardSecurity.littleEndian32(options.normalizedPermissions))
    perms.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
    perms.append(options.encryptMetadata ? 0x54 : 0x46)
    perms.append(contentsOf: Array("adb".utf8))
    perms.append(randomBytes(4))
    let permsEncrypted = try PDFCipher.aesCBC(
      key: fileKey, iv: zeroIV, data: perms, encrypt: true)

    var dictionary: [PDFName: PDFValue] = [
      PDFName("Filter"): .name(PDFName("Standard")),
      PDFName("V"): .integer(5),
      PDFName("R"): .integer(6),
      PDFName("Length"): .integer(256),
      PDFName("CF"): .dictionary([
        PDFName("StdCF"): .dictionary([
          PDFName("Type"): .name(PDFName("CryptFilter")),
          PDFName("CFM"): .name(PDFName("AESV3")),
          PDFName("Length"): .integer(32),
          PDFName("AuthEvent"): .name(PDFName("DocOpen")),
        ])
      ]),
      PDFName("StmF"): .name(PDFName("StdCF")),
      PDFName("StrF"): .name(PDFName("StdCF")),
      PDFName("O"): .string(owner),
      PDFName("U"): .string(user),
      PDFName("OE"): .string(ownerEncrypted),
      PDFName("UE"): .string(userEncrypted),
      PDFName("Perms"): .string(permsEncrypted),
      PDFName("P"): .integer(Int64(options.normalizedPermissions)),
      PDFName("EncryptMetadata"): .boolean(options.encryptMetadata),
    ]
    if options.unencryptedEmbeddedFiles {
      dictionary[PDFName("EFF")] = .name(PDFName("Identity"))
    }
    let info = PDFEncryptionInfo(
      profile: .aes256, version: 5, revision: 6, keyLengthBytes: 32,
      permissions: options.normalizedPermissions, encryptMetadata: options.encryptMetadata,
      owner: owner, user: user, ownerEncrypted: ownerEncrypted, userEncrypted: userEncrypted,
      perms: permsEncrypted, fileID: Data(),
      cryptFilters: ["StdCF": PDFEncryptionInfo.CryptFilter(method: .aes256)],
      streamFilterName: "StdCF", stringFilterName: "StdCF",
      embeddedFileFilterName: options.unencryptedEmbeddedFiles ? "Identity" : nil)
    let context = PDFDecryptionContext(info: info, fileKey: fileKey, isOwner: false)
    return PDFEncryptionOutput(
      options: options, fileKey: fileKey, encryptDictionary: dictionary,
      fileID: randomBytes(16), context: context)
  }

  func encryptObject(_ value: PDFValue, id: PDFObjectID) throws -> PDFValue {
    try context.encryptObject(value, id: id)
  }
}

// MARK: - Unlocked documents (protection-preserving saves)

/// P28-020/P28-023: an authenticated protected document together with the
/// encryption state needed to save edits back with the same protection. The
/// password is never retained; only the derived file key and dictionary are.
public struct PDFUnlockedDocument: Sendable {
  public let parsed: ParsedPDF
  public let encryption: PDFEncryptionState

  public init(parsed: ParsedPDF, encryption: PDFEncryptionState) {
    self.parsed = parsed
    self.encryption = encryption
  }
}

/// P28-021: the operation policy for a protected document. Editing is allowed
/// for the owner password or when the modification permission bit is set.
public struct PDFEncryptionState: Sendable {
  public let info: PDFEncryptionInfo
  public let isOwner: Bool
  public let encryptObjectID: PDFObjectID?
  /// Mutable only so `reset()` can zero the file key on lock (P04-025).
  var context: PDFDecryptionContext

  /// P04-025: best-effort clearing of the retained file key; see
  /// `PDFDecryptionContext.reset` for the limits of this hygiene.
  public mutating func reset() {
    context.reset()
  }

  public var allowsEditing: Bool { isOwner || info.allowsModification }

  init(
    info: PDFEncryptionInfo, isOwner: Bool, encryptObjectID: PDFObjectID?,
    context: PDFDecryptionContext
  ) {
    self.info = info
    self.isOwner = isOwner
    self.encryptObjectID = encryptObjectID
    self.context = context
  }

  /// P28-020: a full rewrite with the same file key and encryption dictionary,
  /// so the saved bytes keep the original passwords, permissions, and
  /// profile. The /Encrypt dictionary object itself is never re-encrypted.
  public func writeReencrypted(_ graph: PDFGraph, limits: PDFLimits = PDFLimits()) throws -> Data {
    var output = graph
    for (id, value) in graph.objects {
      if id == encryptObjectID { continue }
      output.objects[id] = try context.encryptObject(value, id: id)
    }
    return try PDFWriter.serialize(output, limits: limits)
  }

  /// Verify protected output without the password by re-parsing with the
  /// authenticated context.
  public func verifyReencrypted(
    _ data: Data, against graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws {
    let reparsed = try PDFParser.parse(data, decryptionContext: context, limits: limits)
    var expected = graph
    if let size = reparsed.graph.trailer[PDFName("Size")] {
      expected.trailer[PDFName("Size")] = size
    }
    guard reparsed.graph == expected else {
      throw PDFError(
        .malformed, "Protected output failed verification against the edited graph")
    }
  }
}
