import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// RED-05: selective hidden-data sanitization evidence.
@Suite("Redaction sanitization (RED-05)")
struct RedactionSanitizationTests {
  @Test func reviewFindsEveryRetainedCategory() throws {
    let fixture = try RedactionAdversarialFixture.make()
    let parsed = try PDFParser.parse(fixture.data)
    let review = try RedactionHiddenDataReviewer.review(
      in: parsed.graph, revisionCount: parsed.revisionCount)
    #expect(review.pageCount == 1)
    #expect(review.count(.documentInfo) >= 1)
    #expect(review.count(.xmpMetadata) >= 1)
    #expect(review.count(.pageMetadata) >= 1)
    #expect(review.count(.comments) >= 1)
    #expect(review.count(.attachments) == 1)
    #expect(review.count(.actions) >= 1)
    #expect(review.count(.optionalContent) >= 1)
    #expect(review.count(.alternateText) >= 1)
    #expect(review.count(.formValues) >= 2)
    #expect(review.count(.xfaForms) == 1)
    #expect(review.count(.thumbnails) == 1)
    #expect(review.count(.privateApplicationData) >= 1)
    #expect(review.count(.documentIdentifiers) == 1)
    #expect(review.count(.unreachableObjects) >= 1)
    #expect(review.count(.earlierRevisions) == 1)
    #expect(review.details(.attachments).contains("secret.txt"))
    #expect(review.summary.contains("Retained data review"))
  }

  @Test func securePolicyRemovesEveryCategoryAndBytesVerify() throws {
    let fixture = try RedactionAdversarialFixture.make()
    let parsed = try PDFParser.parse(fixture.data)
    let sanitized = try RedactionSanitizer.sanitize(
      in: parsed.graph, policy: .secure, revisionCount: parsed.revisionCount)
    let report = sanitized.report
    for category in [
      RedactionHiddenDataCategory.documentInfo, .xmpMetadata, .pageMetadata, .comments,
      .attachments, .actions, .optionalContent, .alternateText, .formValues, .xfaForms,
      .thumbnails, .privateApplicationData, .documentIdentifiers, .unreachableObjects,
    ] {
      #expect(
        report.outcome(category) == .removed,
        Comment(rawValue: "\(category) -> \(report.outcome(category))"))
    }
    #expect(report.after.count(.unreachableObjects) == 0)
    #expect(report.transformations.count >= 8)
    #expect(report.isFullySanitized)
    let data = try PDFWriter.write(sanitized.graph)
    let seeds = fixture.seeds.filter { $0 != "VISIBLE-SEED" }
    let verification = RedactionSanitizedOutputVerifier.verify(
      data: data, report: report, seeds: seeds)
    #expect(verification.passed, Comment(rawValue: verification.summary))
    #expect(verification.survivingSeeds.isEmpty)
    #expect(try PDFParser.parse(data).revisionCount == 1)
    #expect(data.range(of: Data("/Prev".utf8)) == nil)
  }

  @Test func selectivePolicyKeepsAllowListedDataAndReportsIt() throws {
    let fixture = try RedactionAdversarialFixture.make()
    let parsed = try PDFParser.parse(fixture.data)
    var policy = RedactionSanitizationPolicy.secure
    policy.allowedAttachmentNames = ["secret.txt"]
    let sanitized = try RedactionSanitizer.sanitize(in: parsed.graph, policy: policy)
    let report = sanitized.report
    #expect(report.outcome(.attachments) == .kept)
    #expect(report.kept.contains { $0.category == .attachments })
    let data = try PDFWriter.write(sanitized.graph)
    #expect(data.range(of: Data("ATTACH-SEED".utf8)) != nil)
    let verification = RedactionSanitizedOutputVerifier.verify(
      data: data, report: report, seeds: ["INFO-SEED", "COMMENT-SEED"])
    #expect(verification.passed, Comment(rawValue: verification.summary))

    var keepComments = RedactionSanitizationPolicy.secure
    keepComments.removeComments = false
    let second = try RedactionSanitizer.sanitize(in: parsed.graph, policy: keepComments)
    #expect(second.report.outcome(.comments) == .kept)
    let secondData = try PDFWriter.write(second.graph)
    let secondParsed = try PDFParser.parse(secondData)
    #expect(
      try RedactionHiddenDataReviewer.review(in: secondParsed.graph).count(.comments) == 1)
    #expect(secondData.count > 0)
    let secondVerification = RedactionSanitizedOutputVerifier.verify(
      data: secondData, report: second.report, seeds: ["INFO-SEED"])
    #expect(secondVerification.passed, Comment(rawValue: secondVerification.summary))
  }

  @Test func verificationRejectsBytesThatViolateThePolicy() throws {
    let fixture = try RedactionAdversarialFixture.make()
    let parsed = try PDFParser.parse(fixture.data)
    let sanitized = try RedactionSanitizer.sanitize(
      in: parsed.graph, policy: .secure, revisionCount: parsed.revisionCount)
    let unsanitized = try PDFWriter.write(parsed.graph)
    let verification = RedactionSanitizedOutputVerifier.verify(
      data: unsanitized, report: sanitized.report, seeds: ["INFO-SEED"])
    #expect(!verification.passed)
    #expect(verification.issues.contains { $0.contains("document information") })
    #expect(verification.survivingSeeds.contains("INFO-SEED"))
  }

  @Test func hiddenLayerContentIsRemovedFromContentAndExtraction() throws {
    let fixture = try RedactionAdversarialFixture.make()
    let parsed = try PDFParser.parse(fixture.data)
    let pageID = try #require(parsed.pageIDs.first)
    let sanitized = try RedactionSanitizer.sanitize(
      in: parsed.graph, policy: .secure, revisionCount: parsed.revisionCount)
    let content = String(
      decoding: try PageContent.load(pageID: pageID, in: sanitized.graph)
        .segments.flatMap(\.decoded), as: UTF8.self)
    #expect(!content.contains("OC-SEED"))
    let layout = try PageTextLayout.build(pageID: pageID, in: sanitized.graph)
    #expect(!layout.text(in: 0..<layout.clusters.count).contains("OC-SEED"))
    #expect(
      try RedactionHiddenDataReviewer.review(in: sanitized.graph).count(.optionalContent) == 0)
  }

  @Test func retainedFormPaintIsReportedUninspectable() throws {
    let fixture = try RedactionAdversarialFixture.make()
    var parsed = try PDFParser.parse(fixture.data)
    let pageID = try #require(parsed.pageIDs.first)
    let formID = PDFObjectID((parsed.graph.objects.keys.map(\.number).max() ?? 0) + 1)
    var graph = parsed.graph
    graph.objects[formID] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Form")),
          PDFName("BBox"): .array([
            .integer(0), .integer(0), .integer(100), .integer(100),
          ]),
        ],
        bytes: Data("q /OC /Hidden BDC 0 0 10 10 re f EMC Q".utf8)))
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      Issue.record("page missing")
      return
    }
    guard case .dictionary(var resources)? = page[PDFName("Resources")] else {
      Issue.record("resources missing")
      return
    }
    resources[PDFName("XObject")] = .dictionary([PDFName("Fm"): .reference(formID)])
    page[PDFName("Resources")] = .dictionary(resources)
    graph.objects[pageID] = .dictionary(page)
    let sanitized = try RedactionSanitizer.sanitize(in: graph, policy: .secure)
    #expect(!sanitized.report.uninspectable.isEmpty)
    #expect(!sanitized.report.isFullySanitized)
    let data = try PDFWriter.write(sanitized.graph)
    let verification = RedactionSanitizedOutputVerifier.verify(
      data: data, report: sanitized.report)
    #expect(!verification.passed)
    #expect(verification.issues.contains { $0.contains("uninspectable") })
  }

  @Test func encryptedInputRefusesSanitization() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    var graph = parsed.graph
    graph.trailer[PDFName("Encrypt")] = .dictionary([
      PDFName("Filter"): .name(PDFName("Standard"))
    ])
    #expect(throws: PDFError.self) {
      _ = try RedactionSanitizer.sanitize(in: graph, policy: .secure)
    }
  }
}

