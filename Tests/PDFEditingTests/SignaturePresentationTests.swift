import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Security
import Testing

/// SIG-07: visible signature marks and hidden certificate signatures stay
/// distinguishable in the inventory, the report text and the signing APIs.
@Suite("Signature presentation")
struct SignaturePresentationTests {
  func pageID(_ graph: PDFGraph) throws -> PDFObjectID {
    try #require(try PDFPageTree.pageIDs(in: graph).first)
  }

  func tinyAsset() -> SignatureAsset {
    SignatureAsset(
      id: "sig-07-test", kind: .drawn, width: 2, height: 2,
      rgb8: Data(repeating: 0x40, count: 12))
  }

  func fixtureGraph() throws -> PDFGraph {
    try PDFParser.parse(PDFFixtures.onePage()).graph
  }

  func signedGraph(
    _ graph: PDFGraph, identity: SecIdentity, options: PDFSigningOptions
  ) throws -> PDFGraph {
    let data = try PDFSigningWriter.sign(graph, identity: identity, options: options)
    return try PDFParser.parse(data).graph
  }

  func fieldWidget(
    _ name: String, in graph: PDFGraph
  ) throws -> (field: PDFSignatureFieldInfo, widgetID: PDFObjectID) {
    let fields = try PDFSignatureFieldInventory.fields(in: graph)
    let field = try #require(fields.first { $0.name == name })
    let widgetID = try #require(field.widgetID)
    return (field, widgetID)
  }

  @Test func graphicalMarkOnlyIsNeverCryptographicallySigned() throws {
    let graph = try fixtureGraph()
    let pageID = try pageID(graph)
    let command = PlaceSignatureStampCommand(
      pageID: pageID, rect: [72, 72, 272, 132], asset: tinyAsset(),
      options: SignatureStampOptions(includeName: "Test Signer"))
    let marked = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
    let report = try PDFSignaturePresentationAudit.report(in: marked)
    #expect(report.certificateSignatureCount == 0)
    #expect(report.visibleCertificateCount == 0)
    #expect(report.hiddenCertificateCount == 0)
    #expect(report.graphicalMarkCount == 1)
    #expect(report.isCryptographicallySigned == false)
    #expect(report.hasOnlyVisibleSignatureMarks)
    #expect(!report.warnings.isEmpty)
    let mark = try #require(report.graphicalMarks.first)
    #expect(mark.pageIndex == 0)
    #expect(mark.contents?.contains("not a digital signature") == true)
    #expect(report.plainText.contains("not a digital signature"))
    #expect(report.plainText.contains("No certificate signatures"))
  }

  @Test func visibleCertificateSignatureIsReportedAsVisible() throws {
    let material = try #require(try TestSigningMaterial.make())
    defer { material.cleanUp() }
    let graph = try fixtureGraph()
    let signed = try signedGraph(
      graph, identity: material.identity,
      options: PDFSigningOptions(
        fieldName: "VisibleSig", pageIndex: 0, rect: [72, 72, 272, 112]))
    let report = try PDFSignaturePresentationAudit.report(in: signed)
    #expect(report.certificateSignatureCount == 1)
    #expect(report.visibleCertificateCount == 1)
    #expect(report.hiddenCertificateCount == 0)
    #expect(report.graphicalMarkCount == 0)
    #expect(report.isCryptographicallySigned)
    let entry = try #require(report.certificateSignatures.first)
    #expect(entry.visibility == .visible)
    #expect(entry.reason == nil)
    #expect(entry.pageIndex == 0)
    #expect(entry.disclosure.contains("visible field appearance"))
    let (_, widgetID) = try fieldWidget("VisibleSig", in: signed)
    guard case .dictionary(let widget)? = signed.objects[widgetID] else {
      Issue.record("visible signature widget missing")
      return
    }
    #expect(widget[PDFName("AP")] != nil)
    #expect(report.warnings.isEmpty)
  }

  @Test func hiddenCertificateSignatureIsReportedSeparately() throws {
    let material = try #require(try TestSigningMaterial.make())
    defer { material.cleanUp() }
    let graph = try fixtureGraph()
    let data = try PDFHiddenCertificateSigner.sign(
      graph, identity: material.identity,
      options: PDFHiddenCertificateSigningOptions(fieldName: "HiddenSig"))
    let signed = try PDFParser.parse(data).graph
    let report = try PDFSignaturePresentationAudit.report(in: signed)
    #expect(report.certificateSignatureCount == 1)
    #expect(report.visibleCertificateCount == 0)
    #expect(report.hiddenCertificateCount == 1)
    #expect(report.graphicalMarkCount == 0)
    #expect(report.isCryptographicallySigned)
    let entry = try #require(report.hiddenCertificateSignatures.first)
    #expect(entry.visibility == .hidden)
    #expect(entry.reason?.contains("hidden") == true)
    #expect(entry.disclosure.contains("nothing is drawn"))
    #expect(report.plainText.contains("hidden: 1"))
    #expect(report.warnings.contains { $0.contains("without a visible appearance") })
    let (_, widgetID) = try fieldWidget("HiddenSig", in: signed)
    guard case .dictionary(let widget)? = signed.objects[widgetID] else {
      Issue.record("hidden signature widget missing")
      return
    }
    let flags = try #require(PDFSignaturePresentationAudit.integerValue(widget[PDFName("F")]))
    #expect(flags & 0x02 != 0)
    #expect(flags & 0x20 != 0)
    let signatures = try PDFSignatureInventory.signatures(in: signed)
    #expect(signatures.count == 1)
    #expect(signatures.first?.fieldName == "HiddenSig")
  }

  @Test func hiddenFieldCommandCreatesAnInvisibleEmptyField() throws {
    let graph = try fixtureGraph()
    let pageID = try pageID(graph)
    let withField = try PDFEditingEngine.commit(
      PDFTransaction([
        PDFHiddenSignatureFieldCommand(pageID: pageID, fieldName: "HiddenEmpty")
      ]), to: graph)
    let fields = try PDFSignatureFieldInventory.fields(in: withField)
    let field = try #require(fields.first { $0.name == "HiddenEmpty" })
    #expect(field.isSigned == false)
    guard let widgetID = field.widgetID,
      case .dictionary(let widget)? = withField.objects[widgetID],
      let flags = PDFSignaturePresentationAudit.integerValue(widget[PDFName("F")])
    else {
      Issue.record("hidden empty field widget missing")
      return
    }
    #expect(flags & 0x02 != 0)
    #expect(flags & 0x20 != 0)
    do {
      _ = try PDFHiddenSignatureFieldCommand(
        pageID: pageID, fieldName: "HiddenEmpty"
      ).apply(to: withField)
      Issue.record("duplicate hidden field names must refuse")
    } catch let error as PDFError {
      #expect(error.kind == .malformed)
    }
  }

  @Test func hiddenEmptyFieldCanBeSignedIncrementallyWithoutBecomingVisible() throws {
    let material = try #require(try TestSigningMaterial.make())
    defer { material.cleanUp() }
    let graph = try fixtureGraph()
    let pageID = try pageID(graph)
    let withField = try PDFEditingEngine.commit(
      PDFTransaction([
        PDFHiddenSignatureFieldCommand(pageID: pageID, fieldName: "HiddenEmpty")
      ]), to: graph)
    let source = try PDFParser.parse(try PDFWriter.write(withField))
    let data = try PDFSigningWriter.signIncremental(
      source, identity: material.identity,
      options: PDFSigningOptions(
        fieldName: "HiddenEmpty", existingFieldName: "HiddenEmpty"))
    let reopened = try PDFParser.parse(data).graph
    let report = try PDFSignaturePresentationAudit.report(in: reopened)
    #expect(report.certificateSignatureCount == 1)
    #expect(report.hiddenCertificateCount == 1)
    #expect(report.visibleCertificateCount == 0)
    #expect(report.graphicalMarkCount == 0)
  }

  @Test func visibleExistingFieldKeepsItsAppearance() throws {
    let material = try #require(try TestSigningMaterial.make())
    defer { material.cleanUp() }
    let graph = try fixtureGraph()
    let pageID = try pageID(graph)
    let withField = try PDFEditingEngine.commit(
      PDFTransaction([
        AddSignatureFieldCommand(
          pageID: pageID, rect: [72, 72, 272, 112], name: "VisibleExisting")
      ]), to: graph)
    let source = try PDFParser.parse(try PDFWriter.write(withField))
    let data = try PDFSigningWriter.signIncremental(
      source, identity: material.identity,
      options: PDFSigningOptions(
        fieldName: "VisibleExisting", existingFieldName: "VisibleExisting"))
    let reopened = try PDFParser.parse(data).graph
    let report = try PDFSignaturePresentationAudit.report(in: reopened)
    #expect(report.visibleCertificateCount == 1)
    #expect(report.hiddenCertificateCount == 0)
    #expect(report.graphicalMarks.isEmpty)
    let entry = try #require(report.visibleCertificateSignatures.first)
    #expect(entry.visibility == .visible)
    #expect(entry.reason == nil)
  }

  @Test func marksAndHiddenCertificateStayDistinctInOneReport() throws {
    let material = try #require(try TestSigningMaterial.make())
    defer { material.cleanUp() }
    let graph = try fixtureGraph()
    let pageID = try pageID(graph)
    let marked = try PDFEditingEngine.commit(
      PDFTransaction([
        PlaceSignatureStampCommand(
          pageID: pageID, rect: [72, 72, 272, 132], asset: tinyAsset())
      ]), to: graph)
    let data = try PDFHiddenCertificateSigner.sign(
      marked, identity: material.identity,
      options: PDFHiddenCertificateSigningOptions(fieldName: "HiddenMixed"))
    let signed = try PDFParser.parse(data).graph
    let report = try PDFSignaturePresentationAudit.report(in: signed)
    #expect(report.certificateSignatureCount == 1)
    #expect(report.hiddenCertificateCount == 1)
    #expect(report.visibleCertificateCount == 0)
    #expect(report.graphicalMarkCount == 1)
    #expect(report.isCryptographicallySigned)
    #expect(!report.hasOnlyVisibleSignatureMarks)
    let text = report.plainText
    #expect(text.contains("Hidden certificate signature"))
    #expect(text.contains("Visible signature mark"))
    #expect(text.contains("not a digital signature"))
    #expect(report.certificateSignatures.allSatisfy { $0.fieldName == "HiddenMixed" })
    #expect(report.graphicalMarks.allSatisfy { $0.annotationID != nil })
  }

  @Test func presentationDisclosuresSeparateCryptographicFromInk() {
    let visible = PDFSignaturePresentationMode.visibleAppearance
    let hidden = PDFSignaturePresentationMode.hiddenCertificate
    #expect(visible.disclosure.contains("cryptographic signature"))
    #expect(visible.disclosure.contains("painted"))
    #expect(hidden.disclosure.contains("cryptographic signature"))
    #expect(hidden.disclosure.contains("not an ink or drawn signature"))
    #expect(PDFGraphicalSignatureMark.disclosure.contains("not a digital signature"))
    #expect(PDFGraphicalSignatureMark.disclosure.contains("signature mark"))
  }
}
