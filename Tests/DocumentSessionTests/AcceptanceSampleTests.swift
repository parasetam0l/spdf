import CryptoKit
import DocumentSession
import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// SAF-06: licensed acceptance samples for workflows missing from the
/// owner-supplied corpus. These are regression samples, not private-corpus
/// credit and not owner acceptance.
@Suite("Licensed acceptance samples")
struct AcceptanceSampleTests {
  private struct Manifest: Decodable {
    struct PrivateCorpus: Decodable {
      var manifest: String
      var files: Int
      var distinctContents: Int
      var changed: Bool
      var note: String
    }
    struct Sample: Decodable {
      var id: String
      var workflow: String
      var path: String
      var sha256: String
      var license: String
      var task: String
      var expected: String
      var evidence: [String]
      var unsupportedBoundary: String
      var test: String
    }
    var version: Int
    var privateCorpus: PrivateCorpus
    var samples: [Sample]
  }

  private static var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private static func manifest() throws -> Manifest {
    let url = repositoryRoot.appendingPathComponent("Tests/AcceptanceSamples/manifest.json")
    return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
  }

  private static func fixture(_ relative: String) throws -> Data {
    try Data(
      contentsOf: repositoryRoot.appendingPathComponent("Tests/Fixtures/\(relative)"))
  }

  private static func appearanceBytes(_ field: FormField, in graph: PDFGraph) -> Data {
    var result = Data()
    func append(_ value: PDFValue?) {
      switch value {
      case .reference(let id):
        if case .stream(let stream)? = graph.objects[id] {
          result.append(stream.bytes)
        }
      case .stream(let stream):
        result.append(stream.bytes)
      case .dictionary(let states):
        for key in states.keys.sorted() { append(states[key]) }
      default:
        break
      }
    }
    for widget in field.widgets {
      guard let objectID = widget.objectID,
        case .dictionary(let dictionary)? = graph.objects[objectID],
        case .dictionary(let appearance)? = dictionary[PDFName("AP")]
      else { continue }
      append(appearance[PDFName("N")])
    }
    return result
  }

  @Test func manifestDeclaresCompleteSamplesWithoutChangingThePrivateCorpus() throws {
    let manifest = try Self.manifest()
    #expect(manifest.version == 1)
    #expect(manifest.privateCorpus.files == 17)
    #expect(manifest.privateCorpus.distinctContents == 16)
    #expect(!manifest.privateCorpus.changed)
    #expect(manifest.privateCorpus.manifest == "Work/Corpus/manifest.json")
    #expect(manifest.samples.count == 6)
    #expect(
      Set(manifest.samples.map(\.id)) == [
        "forms-value-appearance", "encrypted-session-save", "signed-validation-refusal",
        "ocr-layer-search", "multilingual-extraction", "tagged-accessibility-audit",
      ])
    #expect(Set(manifest.samples.map(\.test)).count == manifest.samples.count)
    let manifestDirectory = Self.repositoryRoot
      .appendingPathComponent("Tests/AcceptanceSamples")
    for sample in manifest.samples {
      #expect(!sample.workflow.isEmpty)
      #expect(!sample.license.isEmpty)
      #expect(!sample.task.isEmpty)
      #expect(!sample.expected.isEmpty)
      #expect(!sample.evidence.isEmpty)
      #expect(!sample.unsupportedBoundary.isEmpty)
      #expect(sample.sha256.count == 64)
      let validHex = sample.sha256.allSatisfy { $0.isHexDigit }
      #expect(validHex)
      let sampleURL = manifestDirectory.appendingPathComponent(sample.path)
      #expect(
        FileManager.default.fileExists(atPath: sampleURL.path),
        "\(sample.id): sample path is missing")
      let bytes = try Data(contentsOf: sampleURL)
      let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      #expect(digest == sample.sha256, "\(sample.id): sample bytes changed")
    }
  }

  @Test func formsValueAppearanceRoundTrip() throws {
    let original = try Self.fixture("form-pages.pdf")
    let session = DocumentEditSession()
    session.load(try PDFSource(data: original))
    try session.fillFormText(fieldName: "name", text: "Acceptance Name")
    try session.apply(
      PDFTransaction([
        SetFormChoiceCommand(fieldName: "department", exportValue: "Support")
      ]))
    try session.setFormButton(fieldName: "agree", state: PDFName("Yes"))
    let saved = try session.bytesForSave()
    #expect(saved != original)
    let reopened = try PDFParser.parse(saved)
    let fields = try FormInventory.fields(
      in: reopened.graph, pageIDs: reopened.pageIDs)
    guard
      let name = fields.first(where: { $0.name == "name" }),
      let department = fields.first(where: { $0.name == "department" }),
      let agree = fields.first(where: { $0.name == "agree" })
    else {
      Issue.record("Acceptance form fields are missing")
      return
    }
    #expect(name.stringValue == "Acceptance Name")
    #expect(department.stringValue == "Support")
    #expect(agree.isChecked)
    #expect(
      String(decoding: Self.appearanceBytes(name, in: reopened.graph), as: UTF8.self)
        .contains("Acceptance Name"))
    #expect(
      String(decoding: Self.appearanceBytes(department, in: reopened.graph), as: UTF8.self)
        .contains("Support"))
    #expect(reopened.pageIDs.count == 2)
  }

  @Test func encryptedSessionSaveRoundTrip() throws {
    let original = try Self.fixture("Encrypted/aes-256-r6.pdf")
    let session = DocumentEditSession()
    try session.loadProtected(try PDFSource(data: original), password: "abc")
    #expect(session.isProtected)
    #expect(session.canEdit)
    #expect(session.protectionAllowsEditing)
    #expect(session.pageIDs.count == 1)
    try session.rotatePage(id: session.pageIDs[0], byDegrees: 90)
    let saved = try session.bytesForSave()
    #expect(throws: PDFError.self) { _ = try PDFParser.parse(saved) }
    let reopened = try PDFParser.unlock(saved, password: "abc")
    #expect(reopened.encryption.info.profile == .aes256)
    guard case .dictionary(let page)? = reopened.parsed.graph.objects[
      reopened.parsed.pageIDs[0]],
      case .integer(let rotation)? = page[PDFName("Rotate")]
    else {
      Issue.record("Encrypted acceptance page is missing")
      return
    }
    #expect(rotation == 90)
  }

  @Test func signedValidationAndRewriteRefusal() throws {
    let original = try Self.fixture("Signed/signed-one-page.pdf")
    let parsed = try PDFParser.parse(original)
    let signatures = try PDFSignatureInventory.signatures(in: parsed.graph)
    #expect(signatures.count == 1)
    guard let signature = signatures.first else { return }
    let validation = PDFSignatureValidator.validate(
      signature, source: original, finalGraph: parsed.graph)
    #expect(validation.crypto == .valid)
    #expect(validation.trust == .unknown)
    #expect(!validation.unsignedChanges)
    #expect(!validation.revocationChecked)
    #expect(throws: PDFError.self) { _ = try PDFWriter.write(parsed.graph) }
  }

  @Test func ocrLayerSearchRoundTrip() throws {
    let original = try PDFFixtures.scannedPages()
    let parsed = try PDFParser.parse(original)
    let pageID = parsed.pageIDs[0]
    let beforeImages = try PDFImageInventory.images(
      in: parsed.graph, pageIDs: [pageID])
    #expect(beforeImages.count == 1)
    let layered = try PDFEditingEngine.commit(
      PDFTransaction([
        AddSearchableTextLayerCommand(
          pageID: pageID,
          lines: [
            SearchableTextLine(
              text: "SCANNED INVOICE 0042", rect: [72, 680, 400, 704],
              confidence: 0.93)
          ])
      ]), to: parsed.graph)
    let saved = try PDFWriter.write(layered)
    let reopened = try PDFParser.parse(saved)
    #expect(OCRLayer.hasGeneratedLayer(in: reopened.graph, pageID: reopened.pageIDs[0]))
    let afterImages = try PDFImageInventory.images(
      in: reopened.graph, pageIDs: [reopened.pageIDs[0]])
    #expect(afterImages.count == 1)
    #expect(afterImages[0].encodedData == beforeImages[0].encodedData)
    let session = DocumentEditSession()
    session.load(try PDFSource(data: saved))
    let index = TextSearchIndex(session: session)
    let matches = try index.search("SCANNED INVOICE")
    #expect(matches.count == 1)
    #expect(matches[0].provenance == .recognizedText)
  }

  @Test func multilingualExtractionRoundTrip() throws {
    let original = try Self.fixture("multilingual-pages.pdf")
    let parsed = try PDFParser.parse(original)
    let layout = try PageTextLayout.build(pageID: parsed.pageIDs[0], in: parsed.graph)
    guard layout.lines.count == 3 else {
      Issue.record("Multilingual acceptance sample must have three lines")
      return
    }
    let before = layout.lines.map { layout.text(in: $0) }
    #expect(before == ["ΑΒΓ", "БВ", "שבא"])
    let reopened = try PDFParser.parse(try PDFWriter.write(parsed.graph))
    let afterLayout = try PageTextLayout.build(
      pageID: reopened.pageIDs[0], in: reopened.graph)
    let after = afterLayout.lines.map { afterLayout.text(in: $0) }
    #expect(after == before)
    #expect(afterLayout.lines.count == 3)
  }

  @Test func taggedAccessibilityAuditRoundTrip() throws {
    let original = try PDFFixtures.taggedPages()
    let parsed = try PDFParser.parse(original)
    let audit = PDFAccessibilityAudit.audit(parsed.graph, pageIDs: parsed.pageIDs)
    #expect(audit.passesMachineChecks)
    #expect(audit.errorCount == 0)
    #expect(audit.humanReviewRequirements.count == 7)
    #expect(
      audit.findings.contains {
        $0.rule == "Figure alternate text" && $0.severity == .info
      })
    let reopened = try PDFParser.parse(try PDFWriter.write(parsed.graph))
    let after = PDFAccessibilityAudit.audit(
      reopened.graph, pageIDs: reopened.pageIDs)
    #expect(after.errorCount == audit.errorCount)
    #expect(after.humanReviewRequirements == audit.humanReviewRequirements)
    #expect(after.passesMachineChecks)
  }
}
