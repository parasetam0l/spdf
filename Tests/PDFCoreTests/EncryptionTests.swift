import CoreGraphics
import CryptoKit
import CoreText
import Foundation
import PDFFixtures
import PDFKit
@testable import PDFCore
import Testing

/// P28-001–P28-015 evidence: encryption inventory, profile mapping, primitive
/// vectors, password authentication (published independent files plus
/// CoreGraphics-generated files), string/stream decryption, crypt-filter
/// selection, explicit password errors, and refusal to rewrite encrypted
/// graphs.
@Suite("Encryption")
struct EncryptionTests {
  // MARK: Primitive vectors (P28-003)

  @Test func hashPrimitivesMatchPublishedVectors() {
    // RFC 1321 (MD5) and FIPS 180 (SHA-2).
    #expect(hex(PDFCipher.md5(Data())) == "d41d8cd98f00b204e9800998ecf8427e")
    #expect(hex(PDFCipher.md5(Data("abc".utf8))) == "900150983cd24fb0d6963f7d28e17f72")
    #expect(
      hex(PDFCipher.sha256(Data("abc".utf8)))
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(
      hex(PDFCipher.sha384(Data("abc".utf8)))
        == "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7"
    )
    #expect(
      hex(PDFCipher.sha512(Data("abc".utf8)))
        == "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
    )
  }

  @Test func rc4MatchesRFC6229Vectors() {
    let key = Data((1...16).map(UInt8.init))
    let zeros = Data(repeating: 0, count: 16)
    #expect(hex(PDFCipher.rc4(key: key, data: zeros)) == "9ac7cc9a609d1ef7b2932899cde41b97")
    #expect(PDFCipher.rc4(key: key, data: Data()) == Data())
  }

  @Test func aesCBCMatchesNISTVectors() throws {
    let key = Data(hexBytes: "2b7e151628aed2a6abf7158809cf4f3c")
    let iv = Data(hexBytes: "000102030405060708090a0b0c0d0e0f")
    let plaintext = Data(hexBytes: "6bc1bee22e409f96e93d7e117393172a")
    let encrypted = try PDFCipher.aesCBC(key: key, iv: iv, data: plaintext, encrypt: true)
    #expect(hex(encrypted) == "7649abac8119b246cee98e9b12e9197d")
    #expect(try PDFCipher.aesCBC(key: key, iv: iv, data: encrypted, encrypt: false) == plaintext)
  }

  // MARK: Published independent fixtures (P28-006)

  @Test func publishedEncryptedFixturesAuthenticate() throws {
    let cases: [(file: String, password: String, profile: PDFEncryptionInfo.Profile)] = [
      ("aes-128-r4", "ELXRTQWS", .aes128),
      ("aes-256-r5", "pässwört", .aes256Revision5),
      ("aes-256-r6", "abc", .aes256),
      ("aes-256-r6-unicode", "æøå", .aes256),
      ("aes-256-r6-saslprep", "SªSLprep", .aes256),
    ]
    for entry in cases {
      let data = try fixture(entry.file)
      let parsed = try PDFParser.parse(data, password: entry.password)
      #expect(parsed.pageCount >= 1, "\(entry.file)")
      #expect(parsed.encryption?.profile == entry.profile, "\(entry.file)")
      #expect(parsed.encryptionIsOwner == false, "\(entry.file)")
      // The /Encrypt trailer entry survives, so no rewrite can silently emit
      // decrypted output.
      #expect(parsed.graph.trailer[PDFName("Encrypt")] != nil, "\(entry.file)")
    }
  }

  @Test func decryptedStreamsAreReadable() throws {
    // The reduced R4 file carries only a stub content stream; the text files
    // must show real text operators.
    for (file, password, expectsText) in [
      ("aes-128-r4", "ELXRTQWS", false),
      ("aes-256-r5", "pässwört", true),
      ("aes-256-r6", "abc", true),
      ("aes-256-r6-unicode", "æøå", true),
      ("aes-256-r6-saslprep", "SªSLprep", true),
    ] {
      let parsed = try PDFParser.parse(try fixture(file), password: password)
      guard case .dictionary(let page)? = parsed.graph.objects[parsed.pageIDs[0]],
        case .reference(let contentID)? = page[PDFName("Contents")],
        case .stream(let stream)? = parsed.graph.objects[contentID]
      else {
        Issue.record("\(file): page content stream missing")
        continue
      }
      let decoded = String(decoding: try PDFFilters.decoded(stream), as: UTF8.self)
      #expect(!decoded.isEmpty, "\(file)")
      // Decryption garbage would show up as NUL bytes.
      #expect(!decoded.contains("\u{0}"), "\(file)")
      if expectsText {
        #expect(decoded.contains("Tj") || decoded.contains("TJ"), "\(file)")
      }
    }
  }

  @Test func metadataFlagAndAuthenticationFromPublishedFile() throws {
    // bug1782186 (reduced) uses /EncryptMetadata false and dummy objects that
    // need repair scanning for a full load, but its encryption dictionary and
    // password are clean, so the inventory and authentication are verified
    // directly.
    let data = try fixture("aes-128-r4-metadata")
    let info = try #require(try PDFParser.encryptionInventory(data))
    #expect(info.profile == .aes128)
    #expect(info.encryptMetadata == false)
    #expect(info.streamFilterName == "StdCF")
    #expect(info.stringFilterName == "Identity")
    #expect(info.allowsCopying == false)
    let security = PDFStandardSecurity(info: info)
    #expect(try security.authenticate(password: "Hello") != nil)
    #expect(try security.authenticate(password: "wrong") == nil)
  }

  @Test func metadataStreamsAreSkippedOnlyWhenTheFlagIsFalse() throws {
    func context(encryptMetadata: Bool) throws -> PDFDecryptionContext {
      let dictionary: [PDFName: PDFValue] = [
        PDFName("Filter"): .name(PDFName("Standard")),
        PDFName("V"): .integer(4), PDFName("R"): .integer(4),
        PDFName("Length"): .integer(128),
        PDFName("EncryptMetadata"): .boolean(encryptMetadata),
        PDFName("O"): .string(Data(repeating: 0, count: 32)),
        PDFName("U"): .string(Data(repeating: 0, count: 32)),
        PDFName("P"): .integer(-1),
        PDFName("CF"): .dictionary([
          PDFName("StdCF"): .dictionary([
            PDFName("CFM"): .name(PDFName("AESV2")), PDFName("Length"): .integer(16),
          ])
        ]),
        PDFName("StmF"): .name(PDFName("StdCF")),
        PDFName("StrF"): .name(PDFName("StdCF")),
      ]
      let info = try PDFEncryptionInfo.parse(
        trailer: [PDFName("Encrypt"): .dictionary(dictionary)]) { _ in nil }
      return PDFDecryptionContext(
        info: info, fileKey: Data(repeating: 1, count: 16), isOwner: false)
    }
    let metadata: [PDFName: PDFValue] = [PDFName("Type"): .name(PDFName("Metadata"))]
    #expect(try context(encryptMetadata: false).streamMethod(for: metadata) == .none)
    #expect(try context(encryptMetadata: true).streamMethod(for: metadata) == .aes128)
    // An explicit /Crypt filter parameter overrides the metadata default.
    let explicit: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Metadata")),
      PDFName("Filter"): .array([.name(PDFName("Crypt"))]),
      PDFName("DecodeParms"): .array([
        .dictionary([PDFName("Name"): .name(PDFName("StdCF"))])
      ]),
    ]
    #expect(try context(encryptMetadata: false).streamMethod(for: explicit) == .aes128)
  }

  @Test func wrongAndMissingPasswordsAreExplicitAndReadOnly() throws {
    let data = try fixture("aes-256-r6")
    let before = data
    do {
      _ = try PDFParser.parse(data)
      Issue.record("Encrypted parse without a password succeeded")
    } catch let error as PDFError {
      #expect(error.kind == .passwordRequired)
    }
    do {
      _ = try PDFParser.parse(data, password: "wrong")
      Issue.record("Encrypted parse with a wrong password succeeded")
    } catch let error as PDFError {
      #expect(error.kind == .incorrectPassword)
    }
    // P28-028: failed attempts never touch the source bytes.
    #expect(data == before)
  }

  @Test func decryptedGraphsRefuseRewriting() throws {
    // P28-027: a decrypted graph is never written back as plaintext.
    let parsed = try PDFParser.parse(try fixture("aes-128-r4"), password: "ELXRTQWS")
    #expect(throws: PDFError.self) {
      _ = try PDFWriter.write(parsed.graph)
    }
  }

  @Test func unsupportedProfilesRefuseExplicitly() throws {
    let base: [PDFName: PDFValue] = [
      PDFName("Filter"): .name(PDFName("Standard")),
      PDFName("O"): .string(Data(repeating: 0, count: 32)),
      PDFName("U"): .string(Data(repeating: 0, count: 32)),
      PDFName("P"): .integer(-1),
    ]
    func merged(_ extra: [PDFName: PDFValue]) -> [PDFName: PDFValue] {
      base.merging(extra) { _, new in new }
    }
    func expectUnsupported(_ dictionary: [PDFName: PDFValue]) {
      do {
        _ = try PDFEncryptionInfo.parse(
          trailer: [PDFName("Encrypt"): .dictionary(dictionary)]) { _ in nil }
        Issue.record("An unsupported encryption dictionary was accepted")
      } catch let error as PDFError {
        #expect(error.kind == .unsupported)
      } catch {
        Issue.record("Unexpected error: \(error)")
      }
    }
    // Public-key security handler.
    expectUnsupported(
      merged([
        PDFName("Filter"): .name(PDFName("Adobe.PubSec")),
        PDFName("V"): .integer(4), PDFName("R"): .integer(4),
      ]))
    // Unknown crypt filter method.
    expectUnsupported(
      merged([
        PDFName("V"): .integer(4), PDFName("R"): .integer(4),
        PDFName("CF"): .dictionary([
          PDFName("StdCF"): .dictionary([PDFName("CFM"): .name(PDFName("Foo"))])
        ]),
        PDFName("StmF"): .name(PDFName("StdCF")),
        PDFName("StrF"): .name(PDFName("StdCF")),
      ]))
    // Identity-only crypt filters.
    expectUnsupported(
      merged([
        PDFName("V"): .integer(4), PDFName("R"): .integer(4),
        PDFName("CF"): .dictionary([
          PDFName("StdCF"): .dictionary([PDFName("CFM"): .name(PDFName("None"))])
        ]),
        PDFName("StmF"): .name(PDFName("StdCF")),
        PDFName("StrF"): .name(PDFName("StdCF")),
      ]))
    // AES-256 with 32-byte entries instead of 48.
    expectUnsupported(
      merged([
        PDFName("V"): .integer(5), PDFName("R"): .integer(6),
        PDFName("OE"): .string(Data(repeating: 0, count: 32)),
        PDFName("UE"): .string(Data(repeating: 0, count: 32)),
        PDFName("Perms"): .string(Data(repeating: 0, count: 16)),
      ]))
    // V3 never existed.
    expectUnsupported(merged([PDFName("V"): .integer(3), PDFName("R"): .integer(3)]))
  }

  @Test func objectKeyMixesNumberGenerationAndAESSuffix() throws {
    // Algorithm 1 pin: MD5(fileKey + num(3 LE) + gen(2 LE) [+ sAlT]) truncated
    // to min(keyLength + 5, 16). Nonzero generations are pinned here because
    // the published files all use generation 0.
    let info = try PDFEncryptionInfo.parse(
      trailer: [
        PDFName("Encrypt"): .dictionary([
          PDFName("Filter"): .name(PDFName("Standard")),
          PDFName("V"): .integer(2), PDFName("R"): .integer(3),
          PDFName("Length"): .integer(128),
          PDFName("O"): .string(Data(repeating: 0, count: 32)),
          PDFName("U"): .string(Data(repeating: 0, count: 32)),
          PDFName("P"): .integer(-1),
        ])
      ]) { _ in nil }
    let context = PDFDecryptionContext(
      info: info, fileKey: Data(repeating: 7, count: 16), isOwner: false)
    var input = Data(repeating: 7, count: 16)
    input.append(contentsOf: [5, 0, 0, 2, 0])
    let expected = Data(Insecure.MD5.hash(data: input).prefix(16))
    #expect(context.objectKey(for: PDFObjectID(5, generation: 2), aes: false) == expected)
    var aesInput = input
    aesInput.append(contentsOf: Array("sAlT".utf8))
    let expectedAES = Data(Insecure.MD5.hash(data: aesInput).prefix(16))
    #expect(context.objectKey(for: PDFObjectID(5, generation: 2), aes: true) == expectedAES)
    // A 5-byte RC4 key truncates to 10 bytes.
    let shortInfo = try PDFEncryptionInfo.parse(
      trailer: [
        PDFName("Encrypt"): .dictionary([
          PDFName("Filter"): .name(PDFName("Standard")),
          PDFName("V"): .integer(1), PDFName("R"): .integer(2),
          PDFName("O"): .string(Data(repeating: 0, count: 32)),
          PDFName("U"): .string(Data(repeating: 0, count: 32)),
          PDFName("P"): .integer(-1),
        ])
      ]) { _ in nil }
    let shortContext = PDFDecryptionContext(
      info: shortInfo, fileKey: Data(repeating: 9, count: 5), isOwner: false)
    #expect(shortContext.objectKey(for: PDFObjectID(1), aes: false).count == 10)
  }

  // MARK: Profile mapping (P28-002)

  @Test func profileMappingMatchesNormativeAlgorithms() throws {
    func info(_ dictionary: [PDFName: PDFValue]) throws -> PDFEncryptionInfo {
      try PDFEncryptionInfo.parse(trailer: [PDFName("Encrypt"): .dictionary(dictionary)]) { _ in nil }
    }
    let base: [PDFName: PDFValue] = [
      PDFName("Filter"): .name(PDFName("Standard")),
      PDFName("O"): .string(Data(repeating: 0, count: 32)),
      PDFName("U"): .string(Data(repeating: 0, count: 32)),
      PDFName("P"): .integer(-1),
    ]
    func merged(_ extra: [PDFName: PDFValue]) -> [PDFName: PDFValue] {
      base.merging(extra) { _, new in new }
    }
    // V1/R2 is 40-bit RC4.
    let r2 = try info(merged([PDFName("V"): .integer(1), PDFName("R"): .integer(2)]))
    #expect(r2.profile == .rc4_40)
    #expect(r2.keyLengthBytes == 5)
    // V2/R3 keeps the declared RC4 key length.
    let r3 = try info(
      merged([
        PDFName("V"): .integer(2), PDFName("R"): .integer(3),
        PDFName("Length"): .integer(40),
      ]))
    #expect(r3.profile == .rc4_128)
    #expect(r3.keyLengthBytes == 5)
    // V4/R4 with AESV2 is AES-128.
    let aes = try info(
      merged([
        PDFName("V"): .integer(4), PDFName("R"): .integer(4),
        PDFName("CF"): .dictionary([
          PDFName("StdCF"): .dictionary([PDFName("CFM"): .name(PDFName("AESV2"))])
        ]),
        PDFName("StmF"): .name(PDFName("StdCF")),
        PDFName("StrF"): .name(PDFName("StdCF")),
      ]))
    #expect(aes.profile == .aes128)
    #expect(aes.keyLengthBytes == 16)
    // V5/R5 and V5/R6 are AES-256 with the two derivations.
    let r5 = try info(
      merged([
        PDFName("V"): .integer(5), PDFName("R"): .integer(5),
        PDFName("O"): .string(Data(repeating: 0, count: 48)),
        PDFName("U"): .string(Data(repeating: 0, count: 48)),
        PDFName("OE"): .string(Data(repeating: 0, count: 32)),
        PDFName("UE"): .string(Data(repeating: 0, count: 32)),
        PDFName("Perms"): .string(Data(repeating: 0, count: 16)),
        PDFName("CF"): .dictionary([
          PDFName("StdCF"): .dictionary([PDFName("CFM"): .name(PDFName("AESV3"))])
        ]),
        PDFName("StmF"): .name(PDFName("StdCF")),
      ]))
    #expect(r5.profile == .aes256Revision5)
    let r6 = try info(
      merged([
        PDFName("V"): .integer(5), PDFName("R"): .integer(6),
        PDFName("O"): .string(Data(repeating: 0, count: 48)),
        PDFName("U"): .string(Data(repeating: 0, count: 48)),
        PDFName("OE"): .string(Data(repeating: 0, count: 32)),
        PDFName("UE"): .string(Data(repeating: 0, count: 32)),
        PDFName("Perms"): .string(Data(repeating: 0, count: 16)),
        PDFName("CF"): .dictionary([
          PDFName("StdCF"): .dictionary([PDFName("CFM"): .name(PDFName("AESV3"))])
        ]),
        PDFName("StmF"): .name(PDFName("StdCF")),
      ]))
    #expect(r6.profile == .aes256)
  }

  // MARK: CoreGraphics-generated files (P28-007/P28-008)

  @Test func coreGraphicsEncryptedFilesOpenAndVerifyOwner() throws {
    for keyLength in [40, 128] {
      let data = try makeEncryptedPDF(
        user: "user", owner: "owner", keyLength: keyLength, allowsCopying: false,
        text: "encrypted hello")
      // CoreGraphics writes V2/R3 for 40-bit keys and V4/R4 AESV2 for
      // 128-bit keys.
      let expectedProfile: PDFEncryptionInfo.Profile = keyLength == 40 ? .rc4_128 : .aes128

      do {
        _ = try PDFParser.parse(data)
        Issue.record("CG-encrypted file parsed without a password")
      } catch let error as PDFError {
        #expect(error.kind == .passwordRequired)
      }

      let parsed = try PDFParser.parse(data, password: "user")
      #expect(parsed.encryption?.profile == expectedProfile)
      #expect(parsed.encryption?.keyLengthBytes == (keyLength == 40 ? 5 : 16))
      #expect(parsed.encryptionIsOwner == false)
      #expect(parsed.pageCount >= 1)
      let content = try decodedPageContent(parsed)
      #expect(content.contains("BT"))
      #expect(content.contains("Tf"))
      #expect(content.contains("TJ"))
      #expect(content.contains("(e)"))

      // P28-007: the owner password authenticates as owner and the permission
      // flags come from the dictionary.
      let ownerParsed = try PDFParser.parse(data, password: "owner")
      #expect(ownerParsed.encryptionIsOwner == true)
      #expect(ownerParsed.encryption?.allowsCopying == false)
      #expect(ownerParsed.encryption?.allowsPrinting == true)

      do {
        _ = try PDFParser.parse(data, password: "nope")
        Issue.record("CG-encrypted file accepted a wrong password")
      } catch let error as PDFError {
        #expect(error.kind == .incorrectPassword)
      }
    }
  }

  // MARK: Helpers

  private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Encrypted/\(name).pdf")
    return try Data(contentsOf: url)
  }

  private func decodedPageContent(_ parsed: ParsedPDF) throws -> String {
    guard case .dictionary(let page)? = parsed.graph.objects[parsed.pageIDs[0]],
      case .reference(let contentID)? = page[PDFName("Contents")],
      case .stream(let stream)? = parsed.graph.objects[contentID]
    else {
      throw PDFError(.malformed, "Page content stream missing")
    }
    return String(decoding: try PDFFilters.decoded(stream), as: UTF8.self)
  }

  private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  private func makeEncryptedPDF(
    user: String, owner: String, keyLength: Int, allowsCopying: Bool, text: String
  ) throws -> Data {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
      throw PDFError(.malformed, "Could not create a data consumer")
    }
    var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 200)
    var info: [CFString: Any] = [
      kCGPDFContextUserPassword: user as CFString,
      kCGPDFContextOwnerPassword: owner as CFString,
      kCGPDFContextAllowsCopying: allowsCopying,
    ]
    info[kCGPDFContextEncryptionKeyLength] = keyLength
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary)
    else {
      throw PDFError(.malformed, "Could not create an encrypted PDF context")
    }
    context.beginPDFPage(nil)
    let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
        red: 0, green: 0, blue: 0, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: text, attributes: attributes))
    context.textPosition = CGPoint(x: 20, y: 100)
    CTLineDraw(line, context)
    context.endPDFPage()
    context.closePDF()
    return data as Data
  }
}

extension Data {
  fileprivate init(hexBytes: String) {
    var bytes: [UInt8] = []
    var index = hexBytes.startIndex
    while index < hexBytes.endIndex {
      let next = hexBytes.index(index, offsetBy: 2, limitedBy: hexBytes.endIndex) ?? hexBytes.endIndex
      bytes.append(UInt8(hexBytes[index..<next], radix: 16) ?? 0)
      index = next
    }
    self.init(bytes)
  }
}

// MARK: - Encrypted writing (P28-016–P28-019, P28-025, P28-026, P28-029)

extension EncryptionTests {
  @Test func encryptedRoundTripWithIndependentReader() throws {
    let original = try PDFParser.parse(PDFFixtures.threePages())
    let options = PDFEncryptionOptions(userPassword: "secret", ownerPassword: "master")
    let data = try PDFWriter.write(original.graph, encryption: options)

    // The raw output carries no plaintext fixture text.
    #expect(data.range(of: Data("sPDF Editor fixture".utf8)) == nil)

    do {
      _ = try PDFParser.parse(data)
      Issue.record("Encrypted output parsed without a password")
    } catch let error as PDFError {
      #expect(error.kind == .passwordRequired)
    }
    do {
      _ = try PDFParser.parse(data, password: "wrong")
      Issue.record("Encrypted output accepted a wrong password")
    } catch let error as PDFError {
      #expect(error.kind == .incorrectPassword)
    }

    let parsed = try PDFParser.parse(data, password: "secret")
    #expect(parsed.encryption?.profile == .aes256)
    #expect(parsed.encryption?.allowsPrinting == true)
    #expect(parsed.encryption?.allowsCopying == true)
    #expect(parsed.encryptionIsOwner == false)
    // Every original object decrypts back byte-identically.
    for (id, value) in original.graph.objects {
      #expect(parsed.graph.objects[id] == value, "object \(id.number)")
    }
    let ownerParsed = try PDFParser.parse(data, password: "master")
    #expect(ownerParsed.encryptionIsOwner == true)

    // P28-025: an independent reader (PDFKit) unlocks and extracts the text.
    let document = try #require(PDFDocument(data: data))
    #expect(document.isLocked)
    #expect(document.unlock(withPassword: "secret"))
    #expect(document.string?.contains("sPDF Editor fixture - page 1") == true)

    // P28-007: the independent reader also authenticates the owner password
    // written by our dictionary, and its permission flags agree.
    let ownerDocument = try #require(PDFDocument(data: data))
    #expect(ownerDocument.unlock(withPassword: "master"))
    #expect(ownerDocument.allowsCopying)
    #expect(ownerDocument.allowsPrinting)
  }

  @Test func permissionsAndUnencryptedStreamsRoundTrip() throws {
    // Only printing and copying are allowed; metadata and embedded files stay
    // unencrypted (P28-026).
    let original = try PDFParser.parse(PDFFixtures.threePages())
    var graph = original.graph
    let metadataXML = "<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?><x:xmpmeta>test</x:xmpmeta>"
    graph.objects[PDFObjectID(50)] = .stream(
      PDFStream(
        dictionary: [PDFName("Type"): .name(PDFName("Metadata"))],
        bytes: Data(metadataXML.utf8)))
    let embeddedBytes = Data("embedded payload".utf8)
    graph.objects[PDFObjectID(51)] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("EmbeddedFile")),
          PDFName("F"): .string(Data("note.txt".utf8)),
        ], bytes: embeddedBytes))
    graph.objects[PDFObjectID(52)] = .dictionary([
      PDFName("Type"): .name(PDFName("Filespec")),
      PDFName("EF"): .dictionary([PDFName("F"): .reference(PDFObjectID(51))]),
    ])

    let options = PDFEncryptionOptions(
      userPassword: "open", permissions: 4 | 16, encryptMetadata: false,
      unencryptedEmbeddedFiles: true)
    let data = try PDFWriter.write(graph, encryption: options)
    // The unencrypted structures are visible in the raw bytes.
    #expect(data.range(of: Data(metadataXML.utf8)) != nil)
    #expect(data.range(of: embeddedBytes) != nil)

    let parsed = try PDFParser.parse(data, password: "open")
    #expect(parsed.encryption?.allowsPrinting == true)
    #expect(parsed.encryption?.allowsCopying == true)
    #expect(parsed.encryption?.allowsModification == false)
    #expect(parsed.encryption?.encryptMetadata == false)
    guard case .stream(let metadata)? = parsed.graph.objects[PDFObjectID(50)] else {
      Issue.record("Metadata stream missing")
      return
    }
    #expect(String(decoding: metadata.bytes, as: UTF8.self) == metadataXML)
    guard case .stream(let embedded)? = parsed.graph.objects[PDFObjectID(51)],
      case .string(let fileName)? = embedded.dictionary[PDFName("F")]
    else {
      Issue.record("Embedded stream missing")
      return
    }
    #expect(embedded.bytes == embeddedBytes)
    #expect(fileName == Data("note.txt".utf8))
    // The ordinary content streams are encrypted in the raw bytes and decrypt
    // back exactly.
    for (id, value) in original.graph.objects {
      #expect(parsed.graph.objects[id] == value, "object \(id.number)")
    }
  }

  @Test func passwordChangeAndRemovalAreFullTransformations() throws {
    let original = try PDFParser.parse(PDFFixtures.threePages())
    let first = try PDFWriter.write(
      original.graph,
      encryption: PDFEncryptionOptions(userPassword: "old", ownerPassword: "oldmaster"))
    let decrypted = try PDFParser.parse(first, password: "old")

    // P28-018: a password change is a full transformation with fresh salts.
    let changed = try PDFWriter.write(
      PDFWriter.removingEncryption(decrypted.graph),
      encryption: PDFEncryptionOptions(userPassword: "new", ownerPassword: "newmaster"))
    #expect(changed != first)
    do {
      _ = try PDFParser.parse(changed, password: "old")
      Issue.record("The old password still opens the changed file")
    } catch let error as PDFError {
      #expect(error.kind == .incorrectPassword)
    }
    let reopened = try PDFParser.parse(changed, password: "new")
    for (id, value) in original.graph.objects {
      #expect(reopened.graph.objects[id] == value, "object \(id.number)")
    }

    // P28-019: authorized removal is a plain verified rewrite of the same
    // graph; nothing else changes.
    let removed = try PDFWriter.write(PDFWriter.removingEncryption(reopened.graph))
    let plain = try PDFParser.parse(removed)
    #expect(plain.graph.objects == original.graph.objects)
    #expect(plain.graph.trailer[PDFName("Encrypt")] == nil)
    #expect(removed.range(of: Data("sPDF Editor fixture".utf8)) != nil)
  }

  @Test func encryptedOutputRejectsProtectedAndSignedInputs() throws {
    let protected = try PDFParser.parse(try fixture("aes-256-r6"), password: "abc")
    do {
      _ = try PDFWriter.write(
        protected.graph, encryption: PDFEncryptionOptions(userPassword: "again"))
      Issue.record("Re-encrypting an already protected graph was accepted")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
    }
    var signed = try PDFParser.parse(PDFFixtures.onePage()).graph
    signed.objects[PDFObjectID(60)] = .dictionary([
      PDFName("Type"): .name(PDFName("Sig")),
      PDFName("ByteRange"): .array([.integer(0), .integer(10), .integer(20), .integer(30)]),
      PDFName("Contents"): .string(Data(repeating: 0, count: 16)),
    ])
    do {
      _ = try PDFWriter.write(signed, encryption: PDFEncryptionOptions(userPassword: "x"))
      Issue.record("Encrypting a signed graph was accepted")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
    }
  }

  @Test func protectedFileCostsStayBounded() throws {
    // P28-029: measure open/decrypt and encrypted-write cost without touching
    // parser limits.
    let encryptedData = try fixture("aes-256-r6")
    let openStart = ContinuousClock.now
    for _ in 0..<20 {
      _ = try PDFParser.parse(encryptedData, password: "abc")
    }
    let openDuration = openStart.duration(to: .now) / 20
    let graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let writeStart = ContinuousClock.now
    for _ in 0..<20 {
      _ = try PDFWriter.write(
        graph, encryption: PDFEncryptionOptions(userPassword: "bench"))
    }
    let writeDuration = writeStart.duration(to: .now) / 20
    print("P28-029 open+decrypt: \(openDuration), encrypted write: \(writeDuration)")
    #expect(openDuration < .seconds(2))
    #expect(writeDuration < .seconds(2))
  }
}
