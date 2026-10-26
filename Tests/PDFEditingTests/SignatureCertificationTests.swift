import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Security
import Testing

/// SIG-04/SIG-05: DocMDP certification and FieldMDP authoring limits, the
/// permitted/forbidden later-signature workflows, the certification report,
/// and the representative signing workflow documentation.
@Suite("Signature certification and field locks")
struct SignatureCertificationTests {
  private func signingTime() -> Date { Date(timeIntervalSince1970: 1_767_225_600) }

  /// One page with two text fields and two empty signature fields so both
  /// FieldMDP actions and multi-signer workflows can be exercised.
  private func workflowDocument() throws -> ParsedPDF {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let pageID = try #require(parsed.pageIDs.first)
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 600, 272, 624], name: "Amount"),
        AddTextFieldCommand(pageID: pageID, rect: [72, 560, 272, 584], name: "ReviewedBy"),
        AddSignatureFieldCommand(
          pageID: pageID, rect: [72, 500, 272, 540], name: "ApproverSignature"),
        AddSignatureFieldCommand(
          pageID: pageID, rect: [72, 440, 272, 480], name: "LockedSignature"),
      ]), to: parsed.graph)
    return try PDFParser.parse(PDFWriter.write(graph))
  }

  private func certificationOptions(
    fieldName: String = "Certification1", existingFieldName: String? = nil
  ) -> PDFSigningOptions {
    PDFSigningOptions(
      fieldName: fieldName, pageIndex: 0, rect: [72, 360, 272, 400],
      signingTime: signingTime(), existingFieldName: existingFieldName)
  }

  private func certify(
    _ source: ParsedPDF, _ material: TestSigningMaterial,
    permission: PDFDocMDPPermission, fieldLock: PDFSignatureFieldLock? = nil,
    existingFieldName: String? = nil
  ) throws -> Data {
    try PDFSignatureAuthoringWriter.signIncremental(
      source, identity: material.identity,
      options: certificationOptions(existingFieldName: existingFieldName),
      authoring: PDFSignatureAuthoring(
        certificationPermission: permission, fieldLock: fieldLock))
  }

  private func signature(named name: String, in graph: PDFGraph) throws -> PDFSignature {
    let fields = try PDFSignatureFieldInventory.fields(in: graph)
    let field = try #require(fields.first { $0.name == name })
    return try #require(field.signature)
  }

  private func decision(
    _ target: PDFSignatureSigningTarget, in graph: PDFGraph
  ) throws -> PDFSignatureSigningDecision {
    try PDFSignatureSigningPolicy.decision(in: graph, target: target)
  }

  private func validate(
    _ signature: PDFSignature, _ data: Data, _ graph: PDFGraph,
    _ material: TestSigningMaterial
  ) -> PDFSignatureValidation {
    PDFSignatureValidator.validate(
      signature, source: data, finalGraph: graph,
      trustedAnchors: [material.caCertificate])
  }

  private func refusal(_ authoring: PDFSignatureAuthoring, in source: ParsedPDF) -> String? {
    do {
      try authoring.validate(in: source.graph)
      return nil
    } catch let error as PDFError {
      return error.message
    } catch {
      return error.localizedDescription
    }
  }

  // MARK: DocMDP authoring

  @Test func certificationAuthoringWritesDocMDPFieldLockAndValidSignature() throws {
    let material = try #require(try TestSigningMaterial.make())
    defer { material.cleanUp() }
    let source = try workflowDocument()
    let lock = PDFSignatureFieldLock(action: .include, fields: ["LockedSignature"])
    let signed = try certify(
      source, material, permission: .formFillAndSign, fieldLock: lock)
    if let directory = ProcessInfo.processInfo.environment["SPDF_SIG_CERT_DIR"] {
      try? FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true)
      let evidenceURL = URL(fileURLWithPath: directory)
      try? signed.write(to: evidenceURL.appendingPathComponent("certification-p2.pdf"))
      try? material.caPEM.write(to: evidenceURL.appendingPathComponent("certification-ca.pem"))
    }
    #expect(signed.starts(with: source.source))

    let parsed = try PDFParser.parse(signed)
    let signatures = try PDFSignatureInventory.signatures(in: parsed.graph)
    #expect(signatures.count == 1)
    let certification = try #require(signatures.first)
    #expect(certification.docMDPPermission == 2)
    #expect(certification.fieldName == "Certification1")

    // The DocMDP and FieldMDP transforms live in the signed signature.
    guard case .array(let references)? = certification.dictionary[PDFName("Reference")]
    else {
      Issue.record("The certification signature has no /Reference array")
      return
    }
    #expect(references.count == 2)
    var sawDocMDP = false
    var sawFieldMDP = false
    for reference in references {
      guard case .dictionary(let dictionary) = reference else { continue }
      let method = dictionary[PDFName("TransformMethod")]
      if method == .name(PDFName("DocMDP")) {
        sawDocMDP = true
        guard case .dictionary(let parameters)? = dictionary[PDFName("TransformParams")]
        else { continue }
        #expect(parameters[PDFName("P")] == .integer(2))
        #expect(parameters[PDFName("V")] == .name(PDFName("1.2")))
      } else if method == .name(PDFName("FieldMDP")) {
        sawFieldMDP = true
        #expect(dictionary[PDFName("DigestMethod")] == .name(PDFName("SHA256")))
        guard case .dictionary(let parameters)? = dictionary[PDFName("TransformParams")]
        else { continue }
        #expect(parameters[PDFName("Action")] == .name(PDFName("Include")))
        #expect(
          parameters[PDFName("Fields")]
            == .array([.string(Data("LockedSignature".utf8))]))
      }
    }
    #expect(sawDocMDP)
    #expect(sawFieldMDP)

    // The catalog /Perms /DocMDP names the signature dictionary.
    guard case .reference(let catalogID)? = parsed.graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = parsed.graph.objects[catalogID],
      case .dictionary(let permissions)? = catalog[PDFName("Perms")],
      case .reference(let docMDPReference)? = permissions[PDFName("DocMDP")]
    else {
      Issue.record("The catalog /Perms /DocMDP reference is missing")
      return
    }
    #expect(docMDPReference == certification.objectID)

    let fields = try PDFSignatureFieldInventory.fields(in: parsed.graph)
    let certificationField = try #require(fields.first { $0.name == "Certification1" })
    #expect(certificationField.isSigned)
    #expect(certificationField.docMDPPermission == 2)
    #expect(certificationField.lock == lock)

    let validation = validate(certification, signed, parsed.graph, material)
    #expect(validation.crypto == .valid)
    #expect(validation.trust == .trusted)
    #expect(!validation.unsignedChanges)
    try SignatureQualificationSupport.verifyWithOpenSSL(
      data: signed, signature: certification, caPEM: material.caPEM)
    #expect(try SignatureQualificationSupport.qpdfCheck(signed))

    let revisions = PDFSignedRevisionReport.build(
      source: signed, graph: parsed.graph, trustedAnchors: [material.caCertificate])
    #expect(revisions.revisions.count == 1)
    #expect(revisions.revisions.first?.isCertification == true)
    #expect(revisions.revisions.first?.docMDPPermission == 2)
  }

  @Test func fullRewriteCertificationAuthorsP3AndLocksAllFields() throws {
    let material = try #require(try TestSigningMaterial.make())
    defer { material.cleanUp() }
    let source = try workflowDocument()
    let signed = try PDFSignatureAuthoringWriter.sign(
      source.graph, identity: material.identity,
      options: certificationOptions(fieldName: "FinalCertification"),
      authoring: PDFSignatureAuthoring(
        certificationPermission: .formFillSignAndAnnotate,
        fieldLock: PDFSignatureFieldLock(action: .all)))
    let parsed = try PDFParser.parse(signed)
    let certification = try signature(named: "FinalCertification", in: parsed.graph)
    #expect(certification.docMDPPermission == 3)
    #expect(validate(certification, signed, parsed.graph, material).crypto == .valid)

    let fields = try PDFSignatureFieldInventory.fields(in: parsed.graph)
    let field = try #require(fields.first { $0.name == "FinalCertification" })
    #expect(field.lock == PDFSignatureFieldLock(action: .all))

    let report = PDFCertificationReport.read(
      source: signed, graph: parsed.graph, trustedAnchors: [material.caCertificate])
    #expect(report.state == .certified)
    #expect(report.permission == .formFillSignAndAnnotate)
    #expect(report.allows(.addAnnotations))
    #expect(!report.allows(.createNewSignatureFields))
    #expect(!report.allows(.modifyExistingContent))
    #expect(!report.locks(covering: "AnyFieldName").isEmpty)
    // An All lock also blocks signing any later signature field.
    if case .refused(let reason) = try decision(
      .existingField(name: "ApproverSignature"), in: parsed.graph)
    {
      #expect(reason.contains("locks"))
    } else {
      Issue.record("The All field lock did not restrict a later signature")
    }
  }

  @Test func certificationOfAnExistingEmptySignatureFieldWorks() throws {
    let material = try #require(try TestSigningMaterial.make())
    defer { material.cleanUp() }
    let source = try workflowDocument()
    let signed = try certify(
      source, material, permission: .formFillAndSign,
      existingFieldName: "ApproverSignature")
    #expect(signed.starts(with: source.source))
    let parsed = try PDFParser.parse(signed)
    let certification = try signature(named: "ApproverSignature", in: parsed.graph)
    #expect(certification.docMDPPermission == 2)
    #expect(validate(certification, signed, parsed.graph, material).crypto == .valid)
    // P2 permits signing another existing field but not creating a new one.
    #expect(try decision(.existingField(name: "LockedSignature"), in: parsed.graph).isAllowed)
    if case .refused(let reason) = try decision(
      .newField(name: "ExtraSignature"), in: parsed.graph)
    {
      #expect(reason.contains("permission 2"))
    } else {
      Issue.record("P2 allowed a new signature field")
    }
  }

  @Test func certificationRequiresTheFirstSignatureAndNeverReplacesDocMDP() throws {
    let material = try #require(try TestSigningMaterial.make())
    defer { material.cleanUp() }
    let source = try workflowDocument()
    let first = try PDFSigningWriter.signIncremental(
      source, identity: material.identity,
      options: PDFSigningOptions(
        signingTime: signingTime(), existingFieldName: "ApproverSignature"))
    let parsedFirst = try PDFParser.parse(first)
    do {
      _ = try certify(parsedFirst, material, permission: .formFillAndSign)
      Issue.record("A certification was authored after an existing signature")
    } catch let error as PDFError {
      #expect(error.message.contains("first signature"))
    }
    let earlier = try signature(named: "ApproverSignature", in: parsedFirst.graph)
    #expect(validate(earlier, first, parsedFirst.graph, material).crypto == .valid)
    #expect(first.starts(with: source.source))

    // An existing catalog DocMDP declaration is never replaced, even without a
    // complete signature for it.
    var graph = source.graph
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    else {
      Issue.record("The fixture catalog is missing")
      return
    }
    let dummyID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    graph.objects[dummyID] = .dictionary([:])
    catalog[PDFName("Perms")] = .dictionary([
      PDFName("DocMDP"): .reference(dummyID)
    ])
    graph.objects[catalogID] = .dictionary(catalog)
    let altered = try PDFParser.parse(PDFWriter.write(graph))
    do {
      _ = try certify(altered, material, permission: .noChanges)
      Issue.record("An existing DocMDP declaration was replaced")
    } catch let error as PDFError {
      #expect(error.message.contains("already declares a DocMDP"))
    }

    // After an authored certification, a second certification is refused.
    let certified = try certify(source, material, permission: .formFillAndSign)
    let parsedCertified = try PDFParser.parse(certified)
    do {
      _ = try certify(parsedCertified, material, permission: .noChanges)
      Issue.record("A second certification was authored")
    } catch let error as PDFError {
      #expect(error.message.contains("first signature"))
    }
  }

  @Test func encryptedDocumentsCannotBeCertified() throws {
    let material = try #require(try TestSigningMaterial.make())
    defer { material.cleanUp() }
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Encrypted/aes-256-r6.pdf")
    let encrypted = try PDFParser.parse(try Data(contentsOf: url), password: "abc")
    do {
      _ = try certify(encrypted, material, permission: .formFillAndSign)
      Issue.record("An encrypted document was certified")
    } catch let error as PDFError {
      #expect(error.message.contains("encrypted"))
    }
  }

  // MARK: Enforcement of authored locks

  @Test func p1RefusesEveryLaterSignatureAndP3PermitsExistingFields() throws {
    let material = try #require(try TestSigningMaterial.make())
    defer { material.cleanUp() }
    let sourceP1 = try workflowDocument()
    let p1 = try certify(sourceP1, material, permission: .noChanges)
    let parsedP1 = try PDFParser.parse(p1)
    if case .refused(let reason) = try decision(
      .existingField(name: "ApproverSignature"), in: parsedP1.graph)
    {
      #expect(reason.contains("permission 1"))
    } else {
      Issue.record("P1 allowed a later signature")
    }
    do {
      _ = try PDFSigningWriter.signIncremental(
        parsedP1, identity: material.identity,
        options: PDFSigningOptions(
          signingTime: signingTime(), existingFieldName: "ApproverSignature"))
      Issue.record("P1 allowed a later incremental signature")
    } catch let error as PDFError {
      #expect(error.message.contains("permission 1"))
    }
    #expect(p1.starts(with: sourceP1.source))
    let p1Certification = try signature(named: "Certification1", in: parsedP1.graph)
    #expect(validate(p1Certification, p1, parsedP1.graph, material).crypto == .valid)

    let sourceP3 = try workflowDocument()
    let p3 = try certify(sourceP3, material, permission: .formFillSignAndAnnotate)
    let parsedP3 = try PDFParser.parse(p3)
    #expect(try decision(.existingField(name: "ApproverSignature"), in: parsedP3.graph).isAllowed)
    let signed = try PDFSigningWriter.signIncremental(
      parsedP3, identity: material.identity,
      options: PDFSigningOptions(
        signingTime: signingTime(), existingFieldName: "ApproverSignature"))
    #expect(signed.starts(with: p3))
  }

  @Test func fieldMDPLocksRestrictLaterIncrementalSignatures() throws {
    let material = try #require(try TestSigningMaterial.make())
    defer { material.cleanUp() }
    let source = try workflowDocument()
    let lock = PDFSignatureFieldLock(action: .include, fields: ["LockedSignature"])
    let certified = try certify(
      source, material, permission: .formFillAndSign, fieldLock: lock)
    let parsed = try PDFParser.parse(certified)

    if case .refused(let reason) = try decision(
      .existingField(name: "LockedSignature"), in: parsed.graph)
    {
      #expect(reason.contains("LockedSignature"))
    } else {
      Issue.record("The authored FieldMDP lock did not restrict its target")
    }
    #expect(try decision(.existingField(name: "ApproverSignature"), in: parsed.graph).isAllowed)

    // A permitted target signs incrementally over the certified bytes; the
    // earlier certification stays cryptographically valid.
    let second = try PDFSigningWriter.signIncremental(
      parsed, identity: material.identity,
      options: PDFSigningOptions(
        signingTime: signingTime(), existingFieldName: "ApproverSignature"))
    #expect(second.starts(with: certified))
    let parsedSecond = try PDFParser.parse(second)
    let certification = try signature(named: "Certification1", in: parsedSecond.graph)
    let certificationValidation = validate(
      certification, second, parsedSecond.graph, material)
    #expect(certificationValidation.crypto == .valid)
    #expect(certificationValidation.unsignedChanges)
    let approval = try signature(named: "ApproverSignature", in: parsedSecond.graph)
    #expect(validate(approval, second, parsedSecond.graph, material).crypto == .valid)

    // The locked target is refused before any bytes are produced.
    do {
      _ = try PDFSigningWriter.signIncremental(
        parsedSecond, identity: material.identity,
        options: PDFSigningOptions(
          signingTime: signingTime(), existingFieldName: "LockedSignature"))
      Issue.record("A FieldMDP-locked field was signed")
    } catch let error as PDFError {
      #expect(error.message.contains("LockedSignature"))
    }

    let report = PDFCertificationReport.read(
      source: second, graph: parsedSecond.graph,
      trustedAnchors: [material.caCertificate])
    #expect(report.state == .certified)
    #expect(report.permission == .formFillAndSign)
    #expect(report.validation?.crypto == .valid)
    #expect(report.validation?.unsignedChanges == true)
    let revisions = PDFSignedRevisionReport.build(
      source: second, graph: parsedSecond.graph,
      trustedAnchors: [material.caCertificate])
    #expect(revisions.revisions.count == 2)
    #expect(revisions.revisions[0].isCertification)
    #expect(!revisions.revisions[1].isCertification)
  }

  @Test func fieldMDPLockCanBeAuthoredOnIncrementalSignatures() throws {
    let material = try #require(try TestSigningMaterial.make())
    defer { material.cleanUp() }
    var source = try workflowDocument()
    let include = PDFSignatureFieldLock(action: .include, fields: ["LockedSignature"])
    let first = try PDFSignatureAuthoringWriter.signIncremental(
      source, identity: material.identity,
      options: PDFSigningOptions(
        signingTime: signingTime(), existingFieldName: "ApproverSignature"),
      authoring: PDFSignatureAuthoring(fieldLock: include))
    source = try PDFParser.parse(first)
    let firstSignature = try signature(named: "ApproverSignature", in: source.graph)
    #expect(firstSignature.docMDPPermission == nil)
    #expect(validate(firstSignature, first, source.graph, material).crypto == .valid)
    if case .refused(let reason) = try decision(
      .existingField(name: "LockedSignature"), in: source.graph)
    {
      #expect(reason.contains("LockedSignature"))
    } else {
      Issue.record("An incremental FieldMDP lock did not restrict its target")
    }
    #expect(try decision(.newField(name: "AnotherSignature"), in: source.graph).isAllowed)

    // Exclude locks the complementary set: the named field stays changeable.
    let source2 = try workflowDocument()
    let exclude = PDFSignatureFieldLock(action: .exclude, fields: ["LockedSignature"])
    let second = try PDFSignatureAuthoringWriter.signIncremental(
      source2, identity: material.identity,
      options: PDFSigningOptions(
        signingTime: signingTime(), existingFieldName: "ApproverSignature"),
      authoring: PDFSignatureAuthoring(fieldLock: exclude))
    let parsedSecond = try PDFParser.parse(second)
    #expect(try decision(.existingField(name: "LockedSignature"), in: parsedSecond.graph).isAllowed)
    if case .refused = try decision(
      .newField(name: "AnotherSignature"), in: parsedSecond.graph)
    {} else {
      Issue.record("The Exclude lock left an unnamed field changeable")
    }
  }

  // MARK: Authoring limits

  @Test func authoringLimitsRefuseUnsafeFieldLocks() throws {
    let source = try workflowDocument()
    func authoring(_ lock: PDFSignatureFieldLock) -> PDFSignatureAuthoring {
      PDFSignatureAuthoring(fieldLock: lock)
    }

    let allWithFields = authoring(
      PDFSignatureFieldLock(action: .all, fields: ["Amount"]))
    #expect(refusal(allWithFields, in: source)?.contains("must not name") == true)

    let emptyInclude = authoring(PDFSignatureFieldLock(action: .include, fields: []))
    #expect(refusal(emptyInclude, in: source)?.contains("at least one field name") == true)

    let unknown = authoring(
      PDFSignatureFieldLock(action: .include, fields: ["MissingField"]))
    #expect(refusal(unknown, in: source)?.contains("not a form field") == true)

    let duplicate = authoring(
      PDFSignatureFieldLock(action: .exclude, fields: ["Amount", "Amount"]))
    #expect(refusal(duplicate, in: source)?.contains("unique") == true)

    let longName = authoring(
      PDFSignatureFieldLock(action: .include, fields: [String(repeating: "F", count: 300)]))
    #expect(refusal(longName, in: source)?.contains("UTF-8 bytes") == true)

    let whitespace = authoring(
      PDFSignatureFieldLock(action: .include, fields: [" Amount"]))
    #expect(refusal(whitespace, in: source)?.contains("whitespace") == true)

    let tooMany = authoring(
      PDFSignatureFieldLock(
        action: .include, fields: (1...257).map { "Field\($0)" }))
    #expect(refusal(tooMany, in: source)?.contains("at most 256") == true)

    #expect(PDFSignatureAuthoring.maximumLockedFields == 256)
    #expect(PDFSignatureAuthoring.maximumFieldNameBytes == 256)
    #expect(PDFSignatureAuthoring.declaredLimits.count >= 5)
    // A valid lock passes validation.
    let valid = authoring(
      PDFSignatureFieldLock(action: .include, fields: ["Amount", "LockedSignature"]))
    #expect(refusal(valid, in: source) == nil)
  }

  // MARK: Certification report and workflow documentation

  @Test func certificationReportShowsPermissionsLocksAndLaterChanges() throws {
    let material = try #require(try TestSigningMaterial.make())
    defer { material.cleanUp() }
    let source = try workflowDocument()
    let unsigned = PDFCertificationReport.read(source: source.source, graph: source.graph)
    #expect(unsigned.state == .notCertified)
    #expect(unsigned.permission == nil)
    #expect(unsigned.allowedChanges == PDFCertificationChange.allCases)
    #expect(unsigned.deniedChanges.isEmpty)
    #expect(unsigned.fieldLocks.isEmpty)
    #expect(unsigned.validation == nil)

    let lock = PDFSignatureFieldLock(action: .include, fields: ["LockedSignature"])
    let certified = try certify(
      source, material, permission: .formFillAndSign, fieldLock: lock)
    let parsed = try PDFParser.parse(certified)
    let report = PDFCertificationReport.read(
      source: certified, graph: parsed.graph,
      trustedAnchors: [material.caCertificate])
    #expect(report.state == .certified)
    #expect(report.permission == .formFillAndSign)
    #expect(report.certificationFieldName == "Certification1")
    #expect(report.allowedChanges == [.fillExistingFormFields, .signExistingSignatureFields])
    #expect(report.deniedChanges.contains(.addAnnotations))
    #expect(report.deniedChanges.contains(.createNewSignatureFields))
    #expect(report.deniedChanges.contains(.modifyExistingContent))
    #expect(report.validation?.crypto == .valid)
    #expect(report.fieldLocks.contains {
      $0.source == .fieldDictionary && $0.lock == lock
        && $0.signingFieldName == "Certification1"
    })
    #expect(report.fieldLocks.contains {
      $0.source == .signatureTransform && $0.lock == lock
    })
    #expect(report.laterChanges.isEmpty)

    // Bytes appended after the last signature are reported, not hidden.
    let appended = SignatureQualificationSupport.appendLaterRevision(certified)
    let appendedReport = PDFCertificationReport.read(
      source: appended, graph: parsed.graph,
      trustedAnchors: [material.caCertificate])
    #expect(appendedReport.laterChanges.contains { $0.contains("not covered") })

    // P3 is a superset of P2; P1 allows no change at all.
    let p3 = try certify(
      try workflowDocument(), material, permission: .formFillSignAndAnnotate)
    let parsedP3 = try PDFParser.parse(p3)
    let p3Report = PDFCertificationReport.read(source: p3, graph: parsedP3.graph)
    #expect(p3Report.permission == .formFillSignAndAnnotate)
    #expect(p3Report.allows(.addAnnotations))
    let p1 = try certify(
      try workflowDocument(), material, permission: .noChanges)
    let parsedP1 = try PDFParser.parse(p1)
    let p1Report = PDFCertificationReport.read(source: p1, graph: parsedP1.graph)
    #expect(p1Report.allowedChanges.isEmpty)
    #expect(p1Report.deniedChanges.count == PDFCertificationChange.allCases.count)

    // An unknown permission value is reported as unsupported, never as P3.
    var mutated = parsed.graph
    if let certificationID = report.certificationSignature?.objectID,
      case .dictionary(var signatureDictionary)? = mutated.objects[certificationID],
      case .array(var references)? = signatureDictionary[PDFName("Reference")],
      case .dictionary(var referenceDictionary) = references[0],
      case .dictionary(var parameters)? = referenceDictionary[PDFName("TransformParams")]
    {
      parameters[PDFName("P")] = .integer(4)
      referenceDictionary[PDFName("TransformParams")] = .dictionary(parameters)
      references[0] = .dictionary(referenceDictionary)
      signatureDictionary[PDFName("Reference")] = .array(references)
      mutated.objects[certificationID] = .dictionary(signatureDictionary)
    }
    let unsupported = PDFCertificationReport.read(source: certified, graph: mutated)
    #expect(unsupported.state == .unsupportedPermission(4))
    #expect(unsupported.permission == nil)
    #expect(unsupported.allowedChanges.isEmpty)

    // Two certification signatures are reported as ambiguous, not chosen.
    let second = try PDFSigningWriter.signIncremental(
      parsed, identity: material.identity,
      options: PDFSigningOptions(
        signingTime: signingTime(), existingFieldName: "ApproverSignature"))
    let parsedSecond = try PDFParser.parse(second)
    var doubled = parsedSecond.graph
    if let secondID = try? signature(
      named: "ApproverSignature", in: parsedSecond.graph).objectID,
      case .dictionary(var signatureDictionary)? = doubled.objects[secondID]
    {
      signatureDictionary[PDFName("Reference")] = .array([
        .dictionary([
          PDFName("Type"): .name(PDFName("SigRef")),
          PDFName("TransformMethod"): .name(PDFName("DocMDP")),
          PDFName("TransformParams"): .dictionary([
            PDFName("Type"): .name(PDFName("TransformParams")),
            PDFName("P"): .integer(2),
            PDFName("V"): .name(PDFName("1.2")),
          ]),
        ])
      ])
      doubled.objects[secondID] = .dictionary(signatureDictionary)
    }
    let multiple = PDFCertificationReport.read(source: second, graph: doubled)
    #expect(multiple.state == .multipleCertifications)
    #expect(multiple.permission == nil)
  }

  @Test func permissionMatrixAndWorkflowGuideMatchTheDeclaredProfile() {
    #expect(PDFDocMDPPermission.allCases.map(\.permissionValue) == [1, 2, 3])
    #expect(PDFDocMDPPermission.noChanges.allowedChanges.isEmpty)
    #expect(
      PDFDocMDPPermission.formFillAndSign.allowedChanges
        == [.fillExistingFormFields, .signExistingSignatureFields])
    #expect(
      Set(PDFDocMDPPermission.formFillSignAndAnnotate.allowedChanges)
        == Set([
          PDFCertificationChange.fillExistingFormFields,
          PDFCertificationChange.signExistingSignatureFields,
          PDFCertificationChange.addAnnotations,
        ]))
    #expect(!PDFDocMDPPermission.noChanges.allows(.addAnnotations))
    #expect(!PDFDocMDPPermission.formFillAndSign.allows(.addAnnotations))
    #expect(PDFDocMDPPermission.formFillSignAndAnnotate.allows(.addAnnotations))
    #expect(PDFDocMDPPermission(permissionValue: 4) == nil)
    #expect(PDFCertificationChange.allCases.filter(\.isStandardCertificationAllowance).count == 3)
    for permission in PDFDocMDPPermission.allCases {
      #expect(!permission.summary.isEmpty)
      #expect(permission.shortName == "P\(permission.permissionValue)")
      for change in PDFCertificationChange.allCases {
        #expect(permission.allows(change) == permission.allowedChanges.contains(change))
      }
    }

    let guide = PDFSigningWorkflowGuide.self
    #expect(guide.personas.count == 5)
    #expect(guide.workflows.count == 3)
    #expect(
      Set(guide.workflows.map(\.id))
        == Set(["individual-signoff", "review-approve", "controlled-publish"]))
    let personaIDs = Set(guide.personas.map(\.id))
    for workflow in guide.workflows {
      #expect(!workflow.steps.isEmpty)
      #expect(!workflow.signerChanges.isEmpty)
      #expect(!workflow.limitations.isEmpty)
      #expect(workflow.personaIDs.allSatisfy(personaIDs.contains))
      #expect(Set(workflow.personaIDs).count == workflow.personaIDs.count)
      #expect(guide.personas(for: workflow).count == workflow.personaIDs.count)
    }
    #expect(
      guide.workflow(id: "review-approve")?.certificationPermission
        == .formFillSignAndAnnotate)
    #expect(
      guide.workflow(id: "controlled-publish")?.certificationPermission
        == .formFillAndSign)
    #expect(guide.workflow(id: "controlled-publish")?.fieldLockExample != nil)
    #expect(guide.workflow(id: "individual-signoff")?.certificationPermission == nil)
    #expect(guide.personas.filter(\.canCertify).map(\.id) == ["document-author", "publisher"])
    #expect(
      guide.persona(id: "approver")?.postCertificationChanges
        .contains(.signExistingSignatureFields) == true)

    let boundaries = guide.declaredBoundaries.joined(separator: " ").lowercased()
    #expect(boundaries.contains("first signature"))
    #expect(boundaries.contains("docmdp"))
    #expect(boundaries.contains("fieldmdp"))
    #expect(boundaries.contains("timestamp"))
    #expect(boundaries.contains("revocation"))
    let gaps = guide.remainingGaps.joined(separator: " ").lowercased()
    #expect(gaps.contains("timestamp"))
    #expect(gaps.contains("revocation"))
    #expect(gaps.contains("long-term"))
    #expect(gaps.contains("incremental annotation"))
  }

  @Test func unrelatedCatalogPermissionsArePreserved() throws {
    let material = try #require(try TestSigningMaterial.make())
    defer { material.cleanUp() }
    let source = try workflowDocument()
    var graph = source.graph
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    else {
      Issue.record("The fixture catalog is missing")
      return
    }
    catalog[PDFName("Perms")] = .dictionary([
      PDFName("UR3"): .name(PDFName("sPDFExample"))
    ])
    graph.objects[catalogID] = .dictionary(catalog)
    let altered = try PDFParser.parse(PDFWriter.write(graph))
    let signed = try certify(altered, material, permission: .formFillAndSign)
    let parsed = try PDFParser.parse(signed)
    guard case .reference(let signedCatalogID)? = parsed.graph.trailer[PDFName("Root")],
      case .dictionary(let signedCatalog)? = parsed.graph.objects[signedCatalogID],
      case .dictionary(let permissions)? = signedCatalog[PDFName("Perms")]
    else {
      Issue.record("The signed catalog /Perms entry is missing")
      return
    }
    #expect(permissions[PDFName("UR3")] == .name(PDFName("sPDFExample")))
    #expect(permissions[PDFName("DocMDP")] != nil)
  }

  @Test func certifiedBytesRefuseContentRewriteAndKeepTheirEvidence() throws {
    let material = try #require(try TestSigningMaterial.make())
    defer { material.cleanUp() }
    let source = try workflowDocument()
    let certified = try certify(source, material, permission: .formFillAndSign)
    let parsed = try PDFParser.parse(certified)
    let before = parsed.graph

    do {
      _ = try PDFSigningWriter.sign(
        parsed.graph, identity: material.identity,
        options: certificationOptions(fieldName: "LateSignature"))
      Issue.record("A signed graph was signed again as a full rewrite")
    } catch let error as PDFError {
      #expect(error.message.contains("already signed"))
    }
    do {
      _ = try PDFWriter.write(parsed.graph)
      Issue.record("A signed graph was rewritten as plain content")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
    }
    #expect(parsed.graph == before)
    let certification = try signature(named: "Certification1", in: parsed.graph)
    let validation = validate(certification, certified, parsed.graph, material)
    #expect(validation.crypto == .valid)
    #expect(!validation.unsignedChanges)
  }
}
