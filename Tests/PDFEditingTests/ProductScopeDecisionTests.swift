import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// SCOPE-01/SCOPE-02: explicit exclusion decisions, security/data-flow
/// boundaries and the obligations a future approved service would have to meet.
@Suite("Product scope decisions")
struct ProductScopeDecisionTests {
  @Test func catalogRecordsAreCompleteAndConsistent() {
    #expect(ProductScopeDecisionCatalog.validationIssues().isEmpty)
    #expect(ProductScopeDecisionCatalog.all.count == 2)
    #expect(ProductScopeDecisionCatalog.explicitExclusions.count == 2)
    #expect(ProductScopeDecisionCatalog.recordVersion >= 1)
    #expect(!ProductScopeDecisionCatalog.decisionDate.isEmpty)
    #expect(ProductScopeDecisionCatalog.boundaryDisclosure.contains("explicit exclusions"))
    #expect(ProductScopeDecisionCatalog.boundaryDisclosure.contains("does not upload"))
    let ids = Set(ProductScopeDecisionCatalog.all.map(\.id))
    #expect(ids == Set(ProductScopeDecisionID.allCases))
  }

  @Test func bothDecisionsAreExplicitLocalOnlyExclusions() {
    for decision in ProductScopeDecisionCatalog.all {
      #expect(decision.status == .explicitExclusion)
      #expect(decision.isExplicitExclusion)
      #expect(!decision.requiresNetworkService)
      #expect(!decision.storesDocumentsRemotely)
      #expect(!decision.hasApprovedServiceIntegration)
      #expect(!decision.hasApprovedOwnedService)
      #expect(decision.networkEndpoints.isEmpty)
      #expect(!decision.dataFlow.isEmpty)
      #expect(decision.dataFlow.contains { $0.description.contains("leave the device") })
      #expect(decision.dataFlow.first?.order == 1)
      #expect(!decision.excludedCapabilities.isEmpty)
      #expect(!decision.securityRequirements.isEmpty)
      #expect(!decision.prerequisites.isEmpty)
      #expect(!decision.completionObligations.isEmpty)
      #expect(!decision.reEvaluationTriggers.isEmpty)
      #expect(!decision.decisionDocumentPath.isEmpty)
      #expect(decision.plainText.contains("Explicit exclusion"))
      #expect(decision.plainText.contains("Security/privacy requirements"))
      #expect(decision.plainText.contains("Completion obligations"))
    }
  }

  @Test func hostedReviewDecisionNamesEveryRoadmapItem() {
    let decision = ProductScopeDecisionCatalog.decision(for: .hostedSharedReview)
    #expect(decision.id.roadmapRow == "SCOPE-01")
    let exclusions = decision.excludedCapabilities.joined(separator: " ").lowercased()
    #expect(exclusions.contains("browser access"))
    #expect(exclusions.contains("document versions"))
    #expect(exclusions.contains("comments"))
    #expect(exclusions.contains("roles"))
    #expect(exclusions.contains("share links"))
    #expect(exclusions.contains("expiry"))
    #expect(exclusions.contains("conflict"))
    #expect(exclusions.contains("audit"))
    let requirements = decision.securityRequirements.joined(separator: " ").lowercased()
    #expect(requirements.contains("authenticated invitations"))
    #expect(requirements.contains("version"))
    #expect(requirements.contains("audit"))
    #expect(requirements.contains("expiry"))
    #expect(requirements.contains("conflict"))
    #expect(requirements.contains("retention"))
    let obligations = decision.completionObligations.joined(separator: " ").lowercased()
    #expect(obligations.contains("multiple invited users"))
    #expect(obligations.contains("controlled document version"))
    #expect(obligations.contains("auditable"))
    #expect(decision.disclosure.lowercased().contains("explicit exclusion"))
    #expect(decision.disclosure.lowercased().contains("creates no accounts"))
    #expect(decision.decisionDocumentPath.contains("DECISION-SCOPE-01.md"))
  }

  @Test func remoteSignatureDecisionKeepsSigningLocalAndNamesServiceObligations() {
    let decision = ProductScopeDecisionCatalog.decision(for: .remoteSignatureRequests)
    #expect(decision.id.roadmapRow == "SCOPE-02")
    let exclusions = decision.excludedCapabilities.joined(separator: " ").lowercased()
    #expect(exclusions.contains("recipient routing"))
    #expect(exclusions.contains("signing links"))
    #expect(exclusions.contains("reminder"))
    #expect(exclusions.contains("status"))
    #expect(exclusions.contains("completion records"))
    let requirements = decision.securityRequirements.joined(separator: " ").lowercased()
    #expect(requirements.contains("service/privacy model"))
    #expect(requirements.contains("recipient verification"))
    #expect(requirements.contains("single-use"))
    #expect(requirements.contains("completion records"))
    #expect(requirements.contains("independently verifiable"))
    #expect(requirements.contains("private keys never leave"))
    let obligations = decision.completionObligations.joined(separator: " ").lowercased()
    #expect(obligations.contains("multi-signer workflow"))
    #expect(obligations.contains("verifiable"))
    #expect(obligations.contains("completion records"))
    #expect(decision.disclosure.lowercased().contains("local certificate signing"))
    #expect(decision.dataFlow.contains { $0.description.localizedCaseInsensitiveContains("locally") })
    #expect(decision.decisionDocumentPath.contains("DECISION-SCOPE-02.md"))
  }

  @Test func decisionRecordsRejectAnyNetworkOrHostedClaim() {
    // The records are the contract; a future edit that silently turns either
    // workflow into a service must trip the catalog validation.
    let boundaries = ProductScopeDecisionCatalog.all.flatMap {
      $0.securityRequirements + $0.completionObligations + [$0.disclosure]
    }.joined(separator: " ").lowercased()
    #expect(boundaries.contains("no silent upload"))
    #expect(boundaries.contains("audit"))
    #expect(boundaries.contains("retention"))
    #expect(!boundaries.contains("endpoint approved"))
    #expect(ProductScopeDecisionCatalog.validationIssues().isEmpty)
  }
}
