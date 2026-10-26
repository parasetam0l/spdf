import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// EXP-04/EXP-05: approved creation-route decisions and bounded verification.
@Suite("Source PDF creation")
struct SourcePDFCreationTests {
  @Test func everySourceKindHasAnApprovedRouteAndNoForbiddenEngine() {
    #expect(SourceDocumentKind.allCases.count == 6)
    for kind in SourceDocumentKind.allCases {
      let decision = SourcePDFCreationPolicy.decision(for: kind)
      #expect(decision.kind == kind)
      #expect(decision.route == kind.approvedRoute)
      #expect(!decision.usesNetwork)
      #expect(!decision.usesEmbeddedWebView)
      #expect(!decision.usesUnauthorizedConverter)
      #expect(!decision.disclosure.isEmpty)
      #expect(!decision.disclosure.lowercased().contains("ghostscript"))
      #expect(!decision.disclosure.lowercased().contains("webview"))
      #expect(decision.route == .boundedSwiftImport ? decision.isBoundedConversion
        : !decision.isBoundedConversion)
    }
    let office = [
      SourceDocumentKind.docx, .xlsx, .pptx, .rtf,
    ]
    for kind in office {
      let decision = SourcePDFCreationPolicy.decision(for: kind)
      #expect(decision.route == .nativeApplicationHandoff)
      #expect(!decision.requiredApplications.isEmpty)
      #expect(decision.handoffSteps.contains { $0.localizedCaseInsensitiveContains("Print")
        || $0.localizedCaseInsensitiveContains("Export") })
      #expect(!decision.requiresAnotherApplication.isEmpty)
      #expect(!decision.manualChecks.isEmpty)
    }
    let plain = SourcePDFCreationPolicy.decision(for: .plainText)
    #expect(plain.route == .boundedSwiftImport)
    #expect(plain.requiredApplications.isEmpty)
    #expect(plain.isBoundedConversion)
    #expect(SourcePDFBoundedCreation.supports(.plainText))
    #expect(!SourcePDFBoundedCreation.supports(.docx))
    #expect(!SourcePDFBoundedCreation.supports(.html))
  }

  @Test func htmlUsesABrowserPrintHandoffWithoutAnEmbeddedWebView() {
    let decision = SourcePDFCreationPolicy.decision(for: .html)
    #expect(decision.route == .browserPrintHandoff)
    #expect(decision.requiredApplications.contains { $0.contains("Safari") || $0.contains("browser") })
    #expect(decision.handoffSteps.contains { $0.localizedCaseInsensitiveContains("Print") })
    #expect(decision.handoffSteps.contains { $0.localizedCaseInsensitiveContains("Save as PDF") })
    #expect(decision.requiresAnotherApplication.contains {
      $0.localizedCaseInsensitiveContains("HTML")
    })
    #expect(decision.disclosure.localizedCaseInsensitiveContains("web view"))
    #expect(decision.disclosure.contains("does not embed"))
    #expect(decision.disclosure.contains("does not upload"))
  }

  @Test func unknownExtensionsHaveNoApprovedRoute() {
    #expect(SourcePDFCreationPolicy.decision(forFileURL: URL(fileURLWithPath: "/tmp/a.docx"))?
      .kind == .docx)
    #expect(SourcePDFCreationPolicy.decision(forFileURL: URL(fileURLWithPath: "/tmp/a.HTML"))?
      .route == .browserPrintHandoff)
    #expect(SourcePDFCreationPolicy.decision(forFileURL: URL(fileURLWithPath: "/tmp/a.xyz")) == nil)
    #expect(SourcePDFCreationPolicy.decision(forFileURL: URL(fileURLWithPath: "/tmp/a")) == nil)
  }

  @Test func boundedPlainTextCreationVerifiesContentButNotLayout() throws {
    let data = try SourcePDFBoundedCreation.make(
      text: String(repeating: "sPDF bounded plain-text creation. ", count: 40))
    let verification = SourcePDFCreationVerifier.verify(
      data, for: .plainText,
      expectations: SourcePDFCreationExpectations(requiresTextContent: true))
    let report = try #require(verification)
    #expect(report.pageCount >= 1)
    #expect(report.textCharacters > 0)
    #expect(report.contentStatus == .verified)
    #expect(report.linksStatus == .notRequested)
    #expect(report.layoutStatus == .notMachineVerifiable)
    #expect(report.isSatisfied)
    #expect(report.plainText.contains("Visual layout fidelity remains a human check"))
  }

  @Test func linkAndTagExpectationsAreReportedSeparately() throws {
    let taggedData = try PDFFixtures.taggedPages()
    let tagged = try #require(SourcePDFCreationVerifier.verify(
      taggedData, for: .html,
      expectations: SourcePDFCreationExpectations(
        requiresTextContent: true, requiresLinks: true, requiresStructureTags: true)))
    #expect(tagged.linkCount > 0)
    #expect(tagged.hasStructureTags)
    #expect(tagged.linksStatus == .verified)
    #expect(tagged.tagsStatus == .verified)

    let plainData = try PDFFixtures.onePage()
    let untagged = try #require(SourcePDFCreationVerifier.verify(
      plainData, for: .html,
      expectations: SourcePDFCreationExpectations(requiresLinks: true,
        requiresStructureTags: true)))
    #expect(untagged.linkCount == 0)
    #expect(!untagged.hasStructureTags)
    #expect(untagged.linksStatus == .missing)
    #expect(untagged.tagsStatus == .missing)
    #expect(!untagged.isSatisfied)
    #expect(untagged.details.contains { $0.contains("No link annotations") })
    #expect(untagged.details.contains { $0.contains("untagged") })
  }

  @Test func missingContentAndInvalidDataAreNotReportedAsPreserved() throws {
    var graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([.integer(0), .integer(0), .integer(612), .integer(792)]),
        ]),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    graph.version = "1.4"
    let data = try PDFWriter.write(graph)
    let report = try #require(SourcePDFCreationVerifier.verify(
      data, for: .docx, expectations: SourcePDFCreationExpectations()))
    #expect(report.pageCount == 1)
    #expect(report.contentStatus == .missing)
    #expect(!report.isSatisfied)
    #expect(SourcePDFCreationVerifier.verify(Data("not a pdf".utf8), for: .html) == nil)
  }

  @Test func officeHandoffOutputIsVerifiedWithoutLayoutClaims() throws {
    let data = try SourcePDFBoundedCreation.make(text: "Office handoff verification")
    let report = try #require(SourcePDFCreationVerifier.verify(
      data, for: .docx,
      expectations: SourcePDFCreationExpectations(requiresTextContent: true)))
    #expect(report.route == .nativeApplicationHandoff)
    #expect(report.contentStatus == .verified)
    #expect(report.layoutStatus == .notMachineVerifiable)
    #expect(report.isSatisfied)
    #expect(report.plainText.contains("never claims"))
  }
}
