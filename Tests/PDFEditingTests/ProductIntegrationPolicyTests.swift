import Foundation
import PDFCore
@testable import PDFEditing
import Testing

@Suite("Product integration and agreement scope (SCOPE-03/04)")
struct ProductIntegrationPolicyTests {
  @Test func localChannelsAreSupportedHostedChannelsRefused() throws {
    for channel in [IntegrationChannel.localFile, .clipboard, .print, .localTemplateBatch] {
      #expect(ProductIntegrationPolicy.decide(channel).isUsable)
      try ProductIntegrationPolicy.requireUsable(channel)
    }
    for channel in [
      IntegrationChannel.hostedSending, .webFormHosting, .remoteSignatureRequest,
      .cloudStorageUpload, .cloudStorageDownload,
    ] {
      #expect(!ProductIntegrationPolicy.decide(channel).isUsable)
      #expect(throws: ProductIntegrationPolicyError.self) {
        try ProductIntegrationPolicy.requireUsable(channel)
      }
    }
    #expect(ProductIntegrationPolicy.selectedHostedService == nil)
  }

  @Test func agreementBatchTracksEachRecipientSeparately() throws {
    let template = AgreementTemplate(
      templateID: "nda", name: "NDA", revision: 2, fields: ["name", "date"])
    let batch = try AgreementBatch.plan(
      template: template,
      recipients: [
        AgreementRecipient(recipientID: "alice", displayName: "Alice"),
        AgreementRecipient(recipientID: "bob", displayName: "Bob"),
      ])
    #expect(batch.outputs.count == 2)
    #expect(Set(batch.outputs.map(\.recipientID)) == ["alice", "bob"])
    #expect(batch.outputs.allSatisfy { $0.outputName.contains($0.recipientID) })
    #expect(batch.audit().isEmpty)
  }

  @Test func duplicatesAndMixingAreRefused() throws {
    let template = AgreementTemplate(
      templateID: "nda", name: "NDA", revision: 1, fields: ["name"])
    #expect(throws: PDFError.self) {
      _ = try AgreementBatch.plan(
        template: template,
        recipients: [
          AgreementRecipient(recipientID: "alice", displayName: "Alice"),
          AgreementRecipient(recipientID: "alice", displayName: "Alice again"),
        ])
    }
    let mixed = AgreementBatch(
      template: template,
      outputs: [
        AgreementRecipientOutput(
          templateID: "nda", templateRevision: 1, recipientID: "alice",
          outputName: "nda-r1-alice.pdf"),
        AgreementRecipientOutput(
          templateID: "nda", templateRevision: 3, recipientID: "bob",
          outputName: "nda-r3-bob.pdf", status: .failed),
      ])
    let issues = mixed.audit()
    #expect(issues.contains { $0.contains("another template revision") })
    #expect(issues.contains { $0.contains("no recorded reason") })
  }

  @Test func templateValidationRefusesAmbiguousMetadata() throws {
    #expect(!AgreementTemplate(templateID: "", name: "NDA", revision: 1, fields: ["a"]).isValid)
    #expect(!AgreementTemplate(templateID: "nda", name: "NDA", revision: 0, fields: ["a"]).isValid)
    #expect(!AgreementTemplate(templateID: "nda", name: "NDA", revision: 1, fields: ["a", "a"]).isValid)
    #expect(AgreementTemplate(templateID: "nda", name: "NDA", revision: 1, fields: ["a", "b"]).isValid)
  }
}

