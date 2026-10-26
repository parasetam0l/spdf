import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import PDFKit
import Testing

/// SIG-08: reusable password/permission presets, the consistent security
/// policy, password change/removal transformations, and independent reader
/// validation of the written protection.
@Suite("Reusable security presets and encryption policy")
struct SecurityPresetTests {
  private func signingTime() -> Date { Date(timeIntervalSince1970: 1_767_225_600) }

  private func graph() throws -> PDFGraph { try PDFParser.parse(PDFFixtures.onePage()).graph }

  private func preset(
    _ id: String = "custom-preset",
    name: String = "Custom preset",
    permissions: PDFPermissionSet,
    requirement: PDFSecurityPasswordRequirement = .userPasswordRequired,
    separateOwner: Bool = true,
    encryptMetadata: Bool = true,
    unencryptedEmbeddedFiles: Bool = false,
    storedCredential: PDFSecurityCredentialReference? = nil
  ) -> PDFSecurityPreset {
    PDFSecurityPreset(
      id: id, name: name, detail: "Test preset", permissions: permissions,
      passwordRequirement: requirement, requiresSeparateOwnerPassword: separateOwner,
      encryptMetadata: encryptMetadata,
      unencryptedEmbeddedFiles: unencryptedEmbeddedFiles,
      storedCredential: storedCredential)
  }

  private func write(
    _ preset: PDFSecurityPreset, graph: PDFGraph,
    user: String? = "user", owner: String? = "owner",
    resolvedStoredPassword: String? = nil
  ) throws -> Data {
    try preset.apply(
      to: graph, userPassword: user, ownerPassword: owner,
      resolvedStoredPassword: resolvedStoredPassword)
  }

  // MARK: Permission bits

  @Test func permissionBitsRoundTripThroughWrittenEncryption() throws {
    let sets: [PDFPermissionSet] = [
      .unrestricted,
      .viewOnly,
      PDFPermissionSet(printing: true),
      PDFPermissionSet(printing: true, highQualityPrinting: true),
      PDFPermissionSet(printing: true, annotation: true, formFilling: true, extraction: true),
      PDFPermissionSet(copying: true, extraction: true),
      PDFPermissionSet(modification: true, assembly: true),
    ]
    for (index, permissions) in sets.enumerated() {
      let preset = preset("preset-\(index)", name: "Preset \(index)", permissions: permissions)
      let data = try write(preset, graph: try graph())
      let parsed = try PDFParser.parse(data, password: "user")
      let info = try #require(parsed.encryption)
      #expect(info.profile == .aes256)
      #expect(info.version == 5 && info.revision == 6)
      #expect(info.permissions == permissions.normalizedPermissions)
      #expect(PDFPermissionSet(permissions: info.permissions) == permissions)
      #expect(preset.verify(against: parsed).isEmpty)
    }
  }

  @Test func permissionNormalizationMatchesTheCoreWriterContract() {
    for raw in Int32(0)..<Int32(256) {
      let set = PDFPermissionSet(permissions: raw)
      #expect(PDFPermissionSet(permissions: set.permissionsValue) == set)
      let core = PDFEncryptionOptions(userPassword: "x", permissions: set.permissionsValue)
      #expect(set.normalizedPermissions == core.normalizedPermissions)
      // Reserved bits are always written and never exposed as permissions.
      #expect(PDFPermissionSet(permissions: set.normalizedPermissions) == set)
    }
    #expect(PDFPermissionSet.unrestricted.normalizedPermissions == -4)
    #expect(PDFPermissionSet(highQualityPrinting: true).isValid == false)
  }

  // MARK: Preset validation and password policy

  @Test func presetValidationRejectsInconsistentChoices() throws {
    func refuses(_ preset: PDFSecurityPreset, contains: String) {
      do {
        try preset.validate()
        Issue.record("Invalid preset was accepted: \(preset.id)")
      } catch let error as PDFError {
        #expect(error.message.contains(contains), "\(error.message)")
      } catch {
        Issue.record("Unexpected error: \(error)")
      }
    }
    refuses(
      preset("bad-hq", name: "Bad", permissions: PDFPermissionSet(highQualityPrinting: true)),
      contains: "high-quality printing")
    refuses(preset("bad-name", name: "", permissions: .viewOnly), contains: "name")
    refuses(preset("Bad Id", name: "Bad", permissions: .viewOnly), contains: "lowercase")
    refuses(preset("-bad", name: "Bad", permissions: .viewOnly), contains: "lowercase")
    refuses(
      preset(
        "no-password", name: "No password", permissions: .viewOnly,
        requirement: .openWithoutPasswordOwnerRequired, separateOwner: false),
      contains: "separate owner password")
    refuses(
      preset(
        "no-password-cred", name: "No password cred", permissions: .viewOnly,
        requirement: .openWithoutPasswordOwnerRequired,
        storedCredential: PDFSecurityCredentialReference(
          identifier: "preset-id", displayName: "Stored")),
      contains: "cannot reuse")
    refuses(
      preset(
        "credential", name: "Credential", permissions: .viewOnly,
        storedCredential: PDFSecurityCredentialReference(
          identifier: "  ", displayName: "Stored")),
      contains: "identifier")
    // The shipped built-ins and a valid custom preset validate.
    for builtIn in PDFSecurityPreset.builtIns {
      try builtIn.validate()
      #expect(!builtIn.passwordSummary.isEmpty)
    }
    try preset("valid", name: "Valid", permissions: .viewOnly).validate()
  }

  @Test func passwordPoliciesResolveOnlyWithRequiredCredentials() throws {
    let viewOnly = preset("view", name: "View", permissions: .viewOnly)
    do {
      _ = try viewOnly.encryptionOptions(userPassword: nil, ownerPassword: "owner")
      Issue.record("A preset requiring an open password resolved without one")
    } catch let error as PDFError {
      #expect(error.message.contains("open (user) password"))
    }
    do {
      _ = try viewOnly.encryptionOptions(userPassword: "user", ownerPassword: nil)
      Issue.record("A preset requiring a separate owner password resolved without one")
    } catch let error as PDFError {
      #expect(error.message.contains("separate owner password"))
    }
    do {
      _ = try viewOnly.encryptionOptions(userPassword: "same", ownerPassword: "same")
      Issue.record("An owner password equal to the user password was accepted")
    } catch let error as PDFError {
      #expect(error.message.contains("differ"))
    }
    let options = try viewOnly.encryptionOptions(userPassword: "user", ownerPassword: "owner")
    #expect(options.userPassword == "user")
    #expect(options.ownerPassword == "owner")
    #expect(options.permissions == viewOnly.permissions.normalizedPermissions)

    let noPassword = try #require(
      PDFSecurityPreset.builtIns.first { $0.id == "restricted-no-password" })
    do {
      _ = try noPassword.encryptionOptions(userPassword: "unexpected", ownerPassword: "owner")
      Issue.record("A no-open-password preset accepted a user password")
    } catch let error as PDFError {
      #expect(error.message.contains("opens without a password"))
    }
    let restricted = try noPassword.encryptionOptions(userPassword: nil, ownerPassword: "owner")
    #expect(restricted.userPassword.isEmpty)
    #expect(restricted.ownerPassword == "owner")

    let reference = PDFSecurityCredentialReference(
      identifier: "reuse-preset", displayName: "Reused password")
    let reuse = preset(
      "reuse", name: "Reuse", permissions: .viewOnly, storedCredential: reference)
    do {
      _ = try reuse.encryptionOptions(userPassword: nil, ownerPassword: "owner")
      Issue.record("A stored credential resolved without the Keychain value")
    } catch let error as PDFError {
      #expect(error.message.contains("stored password"))
    }
    let reused = try reuse.encryptionOptions(
      userPassword: nil, ownerPassword: "owner", resolvedStoredPassword: "secret")
    #expect(reused.userPassword == "secret")
    // The preset value and its JSON carry only credential labels.
    let encoded = String(decoding: try JSONEncoder().encode(reuse), as: UTF8.self)
    #expect(encoded.contains("Reused password"))
    #expect(!encoded.contains("secret"))

    let longPassword = String(repeating: "a", count: 128)
    do {
      _ = try viewOnly.encryptionOptions(
        userPassword: longPassword, ownerPassword: "owner")
      Issue.record("An over-long password was silently truncated")
    } catch let error as PDFError {
      #expect(error.message.contains("127"))
    }
  }

  // MARK: Preset store

  @Test func presetStoreRoundTripsDeterministicallyAndValidates() throws {
    var store = PDFSecurityPresetStore()
    #expect(store.allPresets == PDFSecurityPreset.builtIns)
    #expect(store.builtInPresets.count == 7)

    let custom = preset("team-review", name: "Team review", permissions: .viewOnly)
    try store.add(custom)
    #expect(store.allPresets.count == 8)
    #expect(store.preset(id: "team-review") == custom)

    guard let first = try? store.encoded(), let second = try? store.encoded() else {
      Issue.record("The preset store could not be encoded")
      return
    }
    #expect(first == second)
    let reopened = try PDFSecurityPresetStore(data: first)
    #expect(reopened == store)
    let text = String(decoding: first, as: UTF8.self)
    #expect(text.contains("team-review"))
    #expect(text.contains("\"version\":\(PDFSecurityPresetStore.currentVersion)"))

    // Built-in ids and names are protected.
    do {
      try store.add(preset(
        PDFSecurityPreset.builtIns[0].id, name: "Duplicate id", permissions: .viewOnly))
      Issue.record("A built-in preset id was reused")
    } catch let error as PDFError {
      #expect(error.message.contains("built-in"))
    }
    do {
      try store.add(preset("new-id", name: "View only", permissions: .viewOnly))
      Issue.record("A built-in preset name was reused")
    } catch let error as PDFError {
      #expect(error.message.contains("already exists"))
    }
    do {
      try store.remove(id: "view-only")
      Issue.record("A built-in preset was removed")
    } catch let error as PDFError {
      #expect(error.message.contains("Built-in"))
    }
    do {
      try store.replace(preset("view-only", name: "Replaced", permissions: .viewOnly))
      Issue.record("A built-in preset was replaced")
    } catch let error as PDFError {
      #expect(error.message.contains("Built-in"))
    }

    // Custom presets can be replaced and removed; adding a 33rd fails.
    let edited = preset(
      "team-review", name: "Team review v2", permissions: PDFPermissionSet(printing: true))
    try store.replace(edited)
    #expect(store.preset(id: "team-review")?.name == "Team review v2")
    for index in 0..<31 {
      try store.add(preset("bulk-\(index)", name: "Bulk \(index)", permissions: .viewOnly))
    }
    do {
      try store.add(preset("overflow", name: "Overflow", permissions: .viewOnly))
      Issue.record("More than the custom preset limit was accepted")
    } catch let error as PDFError {
      #expect(error.kind == .limitExceeded)
    }
    try store.remove(id: "team-review")
    #expect(store.preset(id: "team-review") == nil)
    store.resetCustomPresets()
    #expect(store.customPresets.isEmpty)

    // Stored data versions and duplicates are validated.
    let versioned = try JSONEncoder().encode(PDFSecurityPresetStore())
    var object = try #require(
      try JSONSerialization.jsonObject(with: versioned) as? [String: Any])
    object["version"] = 99
    let unsupported = try JSONSerialization.data(withJSONObject: object)
    do {
      _ = try PDFSecurityPresetStore(data: unsupported)
      Issue.record("An unsupported preset-store version was accepted")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
    }
    do {
      _ = try PDFSecurityPresetStore(version: 1, customPresets: [custom, custom])
      Issue.record("Duplicate custom presets were accepted")
    } catch let error as PDFError {
      #expect(error.message.contains("Duplicate"))
    }
  }

  // MARK: Written protection and independent validation

  @Test func writtenPresetMatchesEncryptionInventoryAndReaderPermissions() throws {
    let review = try #require(PDFSecurityPreset.builtIns.first { $0.id == "review" })
    let data = try write(review, graph: try graph())
    let parsed = try PDFParser.parse(data, password: "user")
    #expect(review.verify(against: parsed).isEmpty)
    #expect(parsed.encryptionIsOwner == false)
    #expect(parsed.pageIDs.count == 1)

    let document = try #require(PDFDocument(data: data))
    #expect(document.isLocked)
    #expect(document.unlock(withPassword: "user"))
    #expect(!document.isLocked)
    let permissions = try #require(
      parsed.encryption.map { PDFPermissionSet(permissions: $0.permissions) })
    #expect(document.allowsPrinting == permissions.printing)
    #expect(document.allowsCopying == permissions.copying)
    #expect(document.allowsCommenting == (permissions.modification || permissions.annotation))
    #expect(document.allowsFormFieldEntry == (permissions.modification || permissions.formFilling))

    let ownerDocument = try #require(PDFDocument(data: data))
    #expect(ownerDocument.unlock(withPassword: "owner"))
    #expect(ownerDocument.allowsPrinting)
    #expect(ownerDocument.allowsCopying)

    let viewOnly = try #require(PDFSecurityPreset.builtIns.first { $0.id == "view-only" })
    let viewData = try write(viewOnly, graph: try graph())
    let viewDocument = try #require(PDFDocument(data: viewData))
    #expect(viewDocument.unlock(withPassword: "user"))
    #expect(!viewDocument.allowsPrinting)
    #expect(!viewDocument.allowsCopying)
    #expect(!viewDocument.allowsCommenting)
    #expect(!viewDocument.allowsFormFieldEntry)
  }

  @Test func presetVerificationReportsInventoryMismatches() throws {
    let viewData = try write(
      try #require(PDFSecurityPreset.builtIns.first { $0.id == "view-only" }),
      graph: try graph())
    let review = try #require(PDFSecurityPreset.builtIns.first { $0.id == "review" })
    let parsed = try PDFParser.parse(viewData, password: "user")
    let mismatches = review.verify(against: parsed)
    #expect(mismatches.contains { $0.contains("permission bits") })
    let plain = try PDFParser.parse(PDFFixtures.onePage())
    #expect(review.verify(against: plain) == ["The written document is not encrypted"])
  }

  @Test func restrictedNoPasswordPresetStaysRestrictedForIndependentReaders() throws {
    let preset = try #require(
      PDFSecurityPreset.builtIns.first { $0.id == "restricted-no-password" })
    let data = try write(preset, graph: try graph(), user: nil, owner: "owner")
    // The core reader needs the explicit empty password; it authenticates as
    // the user, never the owner.
    let emptyUser = try PDFParser.unlock(data, password: "")
    #expect(emptyUser.encryption.isOwner == false)
    #expect(emptyUser.encryption.info.allowsPrinting)
    #expect(!emptyUser.encryption.info.allowsCopying)
    #expect(!emptyUser.encryption.allowsEditing)
    let owner = try PDFParser.unlock(data, password: "owner")
    #expect(owner.encryption.isOwner)

    let document = try #require(PDFDocument(data: data))
    #expect(document.isEncrypted)
    #expect(document.unlock(withPassword: ""))
    #expect(document.allowsPrinting)
    #expect(!document.allowsCopying)
  }

  @Test func metadataAndEmbeddedFileOptionsSurviveThePreset() throws {
    let metadataXML =
      "<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?><x:xmpmeta>preset</x:xmpmeta>"
    let embeddedBytes = Data("preset embedded payload".utf8)
    var graph = try graph()
    let metadataID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    graph.objects[metadataID] = .stream(
      PDFStream(
        dictionary: [PDFName("Type"): .name(PDFName("Metadata"))],
        bytes: Data(metadataXML.utf8)))
    let embeddedID = PDFObjectID(metadataID.number + 1)
    graph.objects[embeddedID] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("EmbeddedFile")),
          PDFName("F"): .string(Data("note.txt".utf8)),
        ], bytes: embeddedBytes))
    let preset = preset(
      "open-structure", name: "Open structure", permissions: .viewOnly,
      encryptMetadata: false, unencryptedEmbeddedFiles: true)
    let data = try write(preset, graph: graph)
    #expect(data.range(of: Data(metadataXML.utf8)) != nil)
    #expect(data.range(of: embeddedBytes) != nil)
    let parsed = try PDFParser.parse(data, password: "user")
    let info = try #require(parsed.encryption)
    #expect(!info.encryptMetadata)
    #expect(info.embeddedFileFilterName == "Identity")
    #expect(preset.verify(against: parsed).isEmpty)
  }

  @Test func passwordChangeAndRemovalWithPresetsAreVerifiedTransformations() throws {
    let originalParsed = try PDFParser.parse(PDFFixtures.onePage())
    let original = originalParsed.graph
    let firstPreset = try #require(PDFSecurityPreset.builtIns.first { $0.id == "view-only" })
    let first = try write(firstPreset, graph: original, user: "old", owner: "oldmaster")

    let unlocked = try PDFParser.unlock(first, password: "old")
    let secondPreset = try #require(PDFSecurityPreset.builtIns.first { $0.id == "review" })
    let plain = try PDFWriter.removingEncryption(unlocked.parsed.graph)
    let changed = try secondPreset.apply(
      to: plain, userPassword: "new", ownerPassword: "newmaster")
    do {
      _ = try PDFParser.parse(changed, password: "old")
      Issue.record("The old password still opens the changed file")
    } catch let error as PDFError {
      #expect(error.kind == .incorrectPassword)
    }
    let reopened = try PDFParser.parse(changed, password: "new")
    #expect(secondPreset.verify(against: reopened).isEmpty)
    #expect(reopened.encryptionIsOwner == false)
    let changedOwner = try PDFParser.unlock(changed, password: "newmaster")
    #expect(changedOwner.encryption.isOwner)

    // Authorized removal writes the same graph without an /Encrypt entry.
    let removed = try PDFWriter.write(
      PDFWriter.removingEncryption(reopened.graph))
    let plainParsed = try PDFParser.parse(removed)
    #expect(plainParsed.graph.trailer[PDFName("Encrypt")] == nil)
    #expect(plainParsed.pageIDs == originalParsed.pageIDs)
    let document = try #require(PDFDocument(data: removed))
    #expect(!document.isEncrypted)
    #expect(document.string?.contains("sPDF Editor fixture") == true)
  }

  // MARK: Consistent policy

  @Test func securityPolicyMatrixMatchesInventoryAndSessionEditing() throws {
    let unencrypted = try PDFParser.parse(PDFFixtures.onePage())
    let openPolicy = PDFDocumentSecurityPolicy(parsed: unencrypted)
    #expect(!openPolicy.isEncrypted)
    #expect(openPolicy.editSessionAllowed)
    #expect(openPolicy.signingAllowed)
    for operation in PDFProtectedOperation.allCases {
      switch operation {
      case .removeProtection, .exportDecryptedCopy, .changeSecurity:
        #expect(!openPolicy.allows(operation))
      default:
        #expect(openPolicy.allows(operation), "\(operation.rawValue)")
      }
    }
    #expect(openPolicy.rows.count == PDFProtectedOperation.allCases.count)
    for row in openPolicy.rows {
      #expect(row.decision == openPolicy.decision(for: row.operation))
    }

    let preset = try #require(PDFSecurityPreset.builtIns.first { $0.id == "view-only" })
    let data = try write(preset, graph: try graph())
    let userParsed = try PDFParser.parse(data, password: "user")
    let userPolicy = PDFDocumentSecurityPolicy(parsed: userParsed)
    let permissions = try #require(userPolicy.permissions)
    #expect(userPolicy.isEncrypted)
    #expect(!userPolicy.isOwner)
    #expect(!userPolicy.editSessionAllowed)
    #expect(!userPolicy.signingAllowed)
    #expect(!userPolicy.allows(.printLowResolution))
    #expect(!userPolicy.allows(.copyContent))
    #expect(!userPolicy.allows(.modifyContent))
    #expect(userPolicy.allows(.extractForAccessibility))
    #expect(!userPolicy.allows(.signDocument))
    #expect(!userPolicy.allows(.changeSecurity))
    #expect(!userPolicy.allows(.removeProtection))
    #expect(!userPolicy.allows(.exportDecryptedCopy))
    let userState = try PDFParser.unlock(data, password: "user")
    #expect(userPolicy.editSessionAllowed == userState.encryption.allowsEditing)

    let ownerParsed = try PDFParser.parse(data, password: "owner")
    let ownerPolicy = PDFDocumentSecurityPolicy(parsed: ownerParsed)
    #expect(ownerPolicy.isOwner)
    #expect(ownerPolicy.editSessionAllowed)
    #expect(ownerPolicy.allows(.modifyContent))
    #expect(ownerPolicy.allows(.changeSecurity))
    #expect(ownerPolicy.allows(.removeProtection))
    #expect(ownerPolicy.allows(.exportDecryptedCopy))
    #expect(!ownerPolicy.allows(.signDocument))
    #expect(ownerPolicy.permissions == permissions)
    let ownerState = try PDFParser.unlock(data, password: "owner")
    #expect(ownerPolicy.editSessionAllowed == ownerState.encryption.allowsEditing)

    // Permission implications from Table 22 are applied consistently.
    let modification = PDFPermissionSet(modification: true)
    #expect(PDFProtectedOperation.annotate.isAllowed(by: modification))
    #expect(PDFProtectedOperation.fillForms.isAllowed(by: modification))
    #expect(PDFProtectedOperation.assemblePages.isAllowed(by: modification))
    let printOnly = PDFPermissionSet(printing: true)
    #expect(PDFProtectedOperation.printLowResolution.isAllowed(by: printOnly))
    #expect(!PDFProtectedOperation.printHighResolution.isAllowed(by: printOnly))
    #expect(
      PDFProtectedOperation.printHighResolution.isAllowed(
        by: PDFPermissionSet(printing: true, highQualityPrinting: true)))
  }

  @Test func encryptedSigningAndReEncryptionRestrictionsStayConsistent() throws {
    let preset = try #require(PDFSecurityPreset.builtIns.first { $0.id == "encrypt-only" })
    let data = try write(preset, graph: try graph())
    let unlocked = try PDFParser.unlock(data, password: "user")
    let policy = PDFDocumentSecurityPolicy(parsed: unlocked.parsed)
    #expect(!policy.signingAllowed)
    #expect(!policy.allows(.signDocument))
    #expect(policy.decision(for: .signDocument).refusalReason?.contains("encrypted") == true)
    // Re-encrypting an already encrypted graph requires the authorized
    // removal transformation first; the writer refuses the raw decrypted graph.
    do {
      _ = try PDFWriter.write(
        unlocked.parsed.graph, encryption: PDFEncryptionOptions(userPassword: "again"))
      Issue.record("A protected graph was re-encrypted without removal")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
    }
    let clean = try PDFWriter.removingEncryption(unlocked.parsed.graph)
    _ = try PDFWriter.write(
      clean, encryption: PDFEncryptionOptions(userPassword: "again", ownerPassword: "again2"))
  }

  @Test func recipientEncryptionIsDetectedAndExplicitlyRefused() throws {
    #expect(PDFSecurityHandlerKind(filter: "Standard") == .standard)
    #expect(PDFSecurityHandlerKind(filter: "Adobe.PubSec") == .publicKey)
    #expect(PDFSecurityHandlerKind(filter: "Vendor.Other") == .unknown)
    #expect(!PDFRecipientEncryptionProfile.isSupported)
    #expect(PDFRecipientEncryptionProfile.decision.contains("not supported"))
    #expect(PDFRecipientEncryptionProfile.decision.contains("public-key"))

    var graph = try graph()
    let encryptID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    graph.objects[encryptID] = .dictionary([
      PDFName("Filter"): .name(PDFName("Adobe.PubSec")),
      PDFName("V"): .integer(5),
      PDFName("R"): .integer(6),
    ])
    graph.trailer[PDFName("Encrypt")] = .reference(encryptID)
    let data = try PDFWriter.serialize(graph)
    do {
      _ = try PDFParser.parse(data, password: "")
      Issue.record("A certificate-recipient document was opened")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
      #expect(error.message.contains("Adobe.PubSec"))
      #expect(error.message.contains("only the standard handler"))
    }
  }

  // MARK: External validation

  @Test func externalValidatorsAgreeOnTheWrittenPermissions() throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-security-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let evidenceDirectory = ProcessInfo.processInfo.environment["SPDF_SECURITY_EVIDENCE_DIR"]
    if let evidenceDirectory {
      try? FileManager.default.createDirectory(
        atPath: evidenceDirectory, withIntermediateDirectories: true)
    }
    let qpdf = "/opt/homebrew/bin/qpdf"
    let pdfinfo = "/opt/homebrew/bin/pdfinfo"

    func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: tool)
      process.arguments = arguments
      let output = Pipe()
      let errorPipe = Pipe()
      process.standardOutput = output
      process.standardError = errorPipe
      try process.run()
      process.waitUntilExit()
      let stdout = String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      let stderr = String(
        decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      return (process.terminationStatus, stdout + stderr)
    }
    func permissionPhrase(_ value: Bool) -> String { value ? "allowed" : "not allowed" }

    for id in ["view-only", "print-high", "review"] {
      let preset = try #require(PDFSecurityPreset.builtIns.first { $0.id == id })
      let data = try write(preset, graph: try graph())
      let url = temporary.appendingPathComponent("\(id).pdf")
      try data.write(to: url)
      if let evidenceDirectory {
        try? data.write(to: URL(fileURLWithPath: evidenceDirectory)
          .appendingPathComponent("\(id).pdf"))
      }
      let expected = preset.permissions
      let qpdfPath = qpdf
      if FileManager.default.isExecutableFile(atPath: qpdfPath) {
        let result = try run(qpdfPath, ["--check", "--password=user", url.path])
        #expect(result.status == 0)
        let encryption = try run(
          qpdfPath, ["--show-encryption", "--password=user", url.path])
        #expect(encryption.status == 0)
        #expect(encryption.output.contains("R = 6"))
        #expect(encryption.output.contains("P = \(expected.normalizedPermissions)"))
        #expect(encryption.output.contains("stream encryption method: AESv3"))
        #expect(encryption.output.contains(
          "print low resolution: \(permissionPhrase(expected.printing))"))
        #expect(encryption.output.contains(
          "print high resolution: \(permissionPhrase(expected.highQualityPrinting))"))
        #expect(encryption.output.contains(
          "modify forms: \(permissionPhrase(expected.formFilling))"))
        #expect(encryption.output.contains(
          "modify annotations: \(permissionPhrase(expected.annotation))"))
        #expect(encryption.output.contains(
          "extract for any purpose: \(permissionPhrase(expected.copying))"))
        #expect(encryption.output.contains(
          "modify document assembly: \(permissionPhrase(expected.assembly))"))
        if let evidenceDirectory {
          try? encryption.output.write(
            toFile: URL(fileURLWithPath: evidenceDirectory)
              .appendingPathComponent("\(id)-qpdf-show-encryption.txt").path,
            atomically: true, encoding: .utf8)
        }
      }
      if FileManager.default.isExecutableFile(atPath: pdfinfo) {
        let info = try run(pdfinfo, ["-upw", "user", url.path])
        #expect(info.status == 0)
        #expect(info.output.contains("algorithm:AES-256"))
        let flags = [
          "print:\(expected.printing ? "yes" : "no")",
          "copy:\(expected.copying ? "yes" : "no")",
          "change:\(expected.modification ? "yes" : "no")",
          "addNotes:\(expected.annotation ? "yes" : "no")",
        ]
        for flag in flags {
          #expect(info.output.contains(flag))
        }
        if let evidenceDirectory {
          try? info.output.write(
            toFile: URL(fileURLWithPath: evidenceDirectory)
              .appendingPathComponent("\(id)-pdfinfo.txt").path,
            atomically: true, encoding: .utf8)
        }
      }
    }
  }
}
