import Foundation
import PDFCore

/// SCOPE-01/SCOPE-02: explicit product-scope decisions. These records are the
/// machine-readable companion to the decision documents; they declare the
/// current exclusion and the security/data-flow rules any future approved
/// service would have to satisfy. No network code exists behind them.
public enum ProductScopeDecisionID: String, Sendable, Equatable, CaseIterable {
  case hostedSharedReview = "SCOPE-01"
  case remoteSignatureRequests = "SCOPE-02"

  public var roadmapRow: String { rawValue }

  public var title: String {
    switch self {
    case .hostedSharedReview: return "Hosted shared review"
    case .remoteSignatureRequests: return "Remote signature requests"
    }
  }
}

public enum ProductScopeDecisionStatus: String, Sendable, Equatable {
  /// The feature is deliberately outside this product's scope for now.
  case explicitExclusion = "Explicit exclusion"
  /// Would require an approved service/privacy model and security review first.
  case approved = "Approved"
}

/// SCOPE-01/SCOPE-02: one data-flow step. Excluded decisions must show a
/// local-only flow with no upload, account, link or remote document copy.
public struct ProductScopeDataFlowStep: Sendable, Equatable {
  public let order: Int
  public let description: String

  public init(order: Int, description: String) {
    self.order = order
    self.description = description
  }
}

/// SCOPE-01/SCOPE-02: one explicit scope decision, including what is excluded,
/// the local data flow, the security/privacy requirements a future service
/// would need, the obligations that map to the roadmap's Done criteria, and the
/// triggers that would reopen the decision.
public struct ProductScopeDecision: Sendable, Equatable {
  public let id: ProductScopeDecisionID
  public let recordVersion: Int
  public let decisionDate: String
  public let status: ProductScopeDecisionStatus
  public let summary: String
  public let rationale: String
  public let excludedCapabilities: [String]
  public let dataFlow: [ProductScopeDataFlowStep]
  public let securityRequirements: [String]
  public let prerequisites: [String]
  public let completionObligations: [String]
  public let reEvaluationTriggers: [String]
  public let disclosure: String
  public let decisionDocumentPath: String

  /// The current decision is an exclusion: no hosted service is approved.
  public let requiresNetworkService: Bool
  public let storesDocumentsRemotely: Bool
  public let hasApprovedServiceIntegration: Bool
  public let hasApprovedOwnedService: Bool
  /// Always empty for the current decision; a future service decision must
  /// name its endpoints explicitly before any transport code exists.
  public let networkEndpoints: [String]

  public init(
    id: ProductScopeDecisionID, recordVersion: Int, decisionDate: String,
    status: ProductScopeDecisionStatus, summary: String, rationale: String,
    excludedCapabilities: [String], dataFlow: [ProductScopeDataFlowStep],
    securityRequirements: [String], prerequisites: [String],
    completionObligations: [String], reEvaluationTriggers: [String],
    disclosure: String, decisionDocumentPath: String, requiresNetworkService: Bool,
    storesDocumentsRemotely: Bool, hasApprovedServiceIntegration: Bool,
    hasApprovedOwnedService: Bool, networkEndpoints: [String]
  ) {
    self.id = id
    self.recordVersion = recordVersion
    self.decisionDate = decisionDate
    self.status = status
    self.summary = summary
    self.rationale = rationale
    self.excludedCapabilities = excludedCapabilities
    self.dataFlow = dataFlow
    self.securityRequirements = securityRequirements
    self.prerequisites = prerequisites
    self.completionObligations = completionObligations
    self.reEvaluationTriggers = reEvaluationTriggers
    self.disclosure = disclosure
    self.decisionDocumentPath = decisionDocumentPath
    self.requiresNetworkService = requiresNetworkService
    self.storesDocumentsRemotely = storesDocumentsRemotely
    self.hasApprovedServiceIntegration = hasApprovedServiceIntegration
    self.hasApprovedOwnedService = hasApprovedOwnedService
    self.networkEndpoints = networkEndpoints
  }

  public var isExplicitExclusion: Bool { status == .explicitExclusion }

  public var plainText: String {
    var lines = [
      "\(id.roadmapRow) — \(id.title)",
      "Status: \(status.rawValue) (record v\(recordVersion), \(decisionDate))",
      "Summary: \(summary)",
      "Rationale: \(rationale)",
      "Excluded capabilities:",
    ]
    lines.append(contentsOf: excludedCapabilities.map { "  - \($0)" })
    lines.append("Data flow:")
    lines.append(contentsOf: dataFlow.map { "  \($0.order). \($0.description)" })
    lines.append("Security/privacy requirements for any future service:")
    lines.append(contentsOf: securityRequirements.map { "  - \($0)" })
    lines.append("Completion obligations (roadmap Done criteria):")
    lines.append(contentsOf: completionObligations.map { "  - \($0)" })
    lines.append("Re-evaluation triggers:")
    lines.append(contentsOf: reEvaluationTriggers.map { "  - \($0)" })
    lines.append("Disclosure: \(disclosure)")
    lines.append("Decision document: \(decisionDocumentPath)")
    return lines.joined(separator: "\n")
  }
}

/// SCOPE-01/SCOPE-02: the approved decision catalog and its invariants. The
/// catalog contains no transport, account, upload or link code; the tests and
/// the decision documents are the contract.
public enum ProductScopeDecisionCatalog {
  public static let recordVersion = 1
  public static let decisionDate = "2026-10-26"
  public static let boundaryDisclosure = """
    SCOPE-01 and SCOPE-02 are explicit exclusions for this product version. \
    sPDF provides local annotation/revision flows and local certificate \
    signing only. It does not upload documents, create accounts or invite/ \
    share links, route recipients, send reminders, run a hosted review or \
    signature service, or ship network code for either workflow. Any future \
    change requires an approved service/privacy model and security review, \
    and the decision records below then map each roadmap Done criterion to \
    verifiable obligations. The full decision documents live under \
    Work/SCOPE-01-02-Hosted-2026-10-26/.
    """

  public static var all: [ProductScopeDecision] {
    ProductScopeDecisionID.allCases.map(decision(for:))
  }

  public static var explicitExclusions: [ProductScopeDecision] {
    all.filter(\.isExplicitExclusion)
  }

  public static func decision(for id: ProductScopeDecisionID) -> ProductScopeDecision {
    switch id {
    case .hostedSharedReview:
      return ProductScopeDecision(
        id: .hostedSharedReview, recordVersion: recordVersion, decisionDate: decisionDate,
        status: .explicitExclusion,
        summary: "Hosted browser shared review is explicitly excluded; review remains local.",
        rationale: """
          A hosted shared-review workflow would require an approved service operator, \
          identity/accounts, share-link lifecycle, server-side version control and an \
          auditable conflict model. None of those is approved or built, so claiming \
          shared review would create exactly the silent-upload and data-retention risk \
          the product must avoid. Local annotations, comments and revision-friendly \
          saves already cover single-user review; exporting a copy for external review \
          stays a user action in another application.
          """,
        excludedCapabilities: [
          "Browser access to document content or review state",
          "Shared hosted document versions and version switching",
          "Multi-user comments, replies, statuses or real-time sync",
          "Reviewer roles, invitations, permissions or approval workflows",
          "Share links, link expiry/revocation and access logs",
          "Hosted conflict resolution or server-side merge of review changes",
          "Auditable hosted change history or notification of changes",
        ],
        dataFlow: [
          .init(order: 1, description: "The user opens the PDF locally in sPDF."),
          .init(
            order: 2,
            description: "Annotations, comments and revisions are written into the local PDF only."),
          .init(
            order: 3,
            description: "No account, invitation, share link or snapshot is created."),
          .init(
            order: 4,
            description: "No document bytes, comment data or review metadata leave the device."),
          .init(
            order: 5,
            description: "No network transport exists for review; external review is a user-directed handoff."),
        ],
        securityRequirements: [
          "Authenticated invitations only; no anonymous document access",
          "Least-privilege reviewer roles with explicit document-version pinning",
          "Single-use, expiring (explicit expiry) and revocable share links with access logs",
          "Immutable audit trail of comments, version changes and role changes",
          "Documented conflict policy: version vectors or per-version branches, never silent last-write-wins",
          "Retention, export and deletion policy for documents, comments and audit data",
          "Transport and at-rest encryption with a named data controller and residency",
          "No silent upload: the user must explicitly choose and see the destination",
        ],
        prerequisites: [
          "An approved hosted service or owned service architecture",
          "Security review, privacy/retention policy and legal/data-residency review",
          "Independent integration tests proving auditable versions, roles, expiry and conflict handling",
          "A product decision that hosted review is worth the operational and privacy cost",
        ],
        completionObligations: [
          "Multiple invited users can review one controlled document version",
          "Every review change is attributable and auditable",
          "Browser access, document versions, comments, roles, share-link expiry and conflict handling are explicitly defined and enforced",
          "The service/privacy model is approved and disclosed before any upload is possible",
        ],
        reEvaluationTriggers: [
          "A named customer need that local review cannot satisfy",
          "An approved vendor/service with a satisfactory privacy and security review",
          "A budget/ownership decision for operating or procuring the service",
          "A legal/data-residency decision that permits hosting review data",
        ],
        disclosure: """
          Hosted shared review is an explicit exclusion in this product version. \
          Only local annotations, comments and revision-friendly local saves are \
          provided; sPDF creates no accounts, share links, hosted versions or \
          multi-user review state.
          """,
        decisionDocumentPath: "Work/SCOPE-01-02-Hosted-2026-10-26/DECISION-SCOPE-01.md",
        requiresNetworkService: false, storesDocumentsRemotely: false,
        hasApprovedServiceIntegration: false, hasApprovedOwnedService: false,
        networkEndpoints: [])
    case .remoteSignatureRequests:
      return ProductScopeDecision(
        id: .remoteSignatureRequests, recordVersion: recordVersion,
        decisionDate: decisionDate, status: .explicitExclusion,
        summary: "Remote signature requests are explicitly excluded; signing stays local.",
        rationale: """
          Recipient routing, signing links, reminders, hosted status and completion \
          records require an approved trust/identity service or an owned service with a \
          named data controller, recipient verification and immutable completion \
          evidence. None of that is approved, and building partial network plumbing \
          would risk uploading documents or private keys without the service/privacy \
          model the roadmap requires. Local certificate signing and local incremental \
          multi-signer workflows remain available and produce independently verifiable PDFs.
          """,
        excludedCapabilities: [
          "Remote recipient routing or address-book contact handling",
          "Signing links and their single-use/expiry lifecycle",
          "Automated reminder emails or notification delivery",
          "Hosted signature status tracking or dashboards",
          "Hosted completion records or certificate-of-completion service",
          "Remote identity proofing, eIDAS/qualified signature service or credential custody",
          "Any upload of the document or recipient data for signing",
        ],
        dataFlow: [
          .init(order: 1, description: "The user opens the PDF locally and selects an existing signature field or creates one."),
          .init(order: 2, description: "The private key stays in the local keychain or token; signing happens locally."),
          .init(order: 3, description: "Signed bytes and validation evidence remain in the local PDF revision."),
          .init(order: 4, description: "No recipient address, signing link, reminder or status leave the device."),
          .init(order: 5, description: "Delivery of the signed file to recipients is a user action in another application."),
        ],
        securityRequirements: [
          "A clear service/privacy model naming the data controller and signer/recipient roles",
          "Recipient verification and signing-link authentication before signing is permitted",
          "Single-use, expiring, revocable signing links with abuse/rate limits",
          "Reminder policy with explicit consent, opt-out and delivery limits",
          "Immutable, exportable completion records binding signer identity to final document hashes",
          "Independently verifiable final PDFs (existing CMS/DocMDP validation must still pass)",
          "Private keys never leave the origin keychain/token; no server-side signing without explicit qualified-service approval",
          "Retention, deletion and audit policy for recipient data, links and completion records",
        ],
        prerequisites: [
          "An approved service integration or an owned service with a privacy/security model",
          "Legal review of signature evidence requirements in the intended jurisdictions",
          "Trust/identity provider approval if identity proofing is required",
          "End-to-end tests with an independent validator proving final documents and completion records",
        ],
        completionObligations: [
          "A real multi-signer workflow completes with recipient routing, signing links and reminders",
          "Status and completion records are recorded and auditable",
          "Final documents remain independently verifiable and bound to the completion record",
          "The service/privacy model is approved and disclosed before any recipient data is handled",
        ],
        reEvaluationTriggers: [
          "A chosen service integration or owned-service architecture with an approved privacy model",
          "Legal/eIDAS/UETA requirements that local signing cannot satisfy",
          "A customer workflow requiring remote recipient routing and completion evidence",
          "Approval of a trust/identity provider and budget for service operation",
        ],
        disclosure: """
          Remote signature requests are an explicit exclusion in this product \
          version. sPDF performs local certificate signing only: no recipient \
          routing, signing links, reminders, hosted status tracking or completion \
          service exists, and no document or recipient data is uploaded for signing.
          """,
        decisionDocumentPath: "Work/SCOPE-01-02-Hosted-2026-10-26/DECISION-SCOPE-02.md",
        requiresNetworkService: false, storesDocumentsRemotely: false,
        hasApprovedServiceIntegration: false, hasApprovedOwnedService: false,
        networkEndpoints: [])
    }
  }

  /// Structural invariants shared by the decision records. An empty result
  /// means the records are complete and still describe a local-only exclusion.
  public static func validationIssues() -> [String] {
    var issues: [String] = []
    let decisions = all
    if Set(decisions.map(\.id)) != Set(ProductScopeDecisionID.allCases) {
      issues.append("The catalog must contain exactly one record per decision id")
    }
    for decision in decisions {
      if decision.status != .explicitExclusion {
        issues.append("\(decision.id.rawValue) must currently be an explicit exclusion")
      }
      if decision.requiresNetworkService || decision.storesDocumentsRemotely
        || decision.hasApprovedServiceIntegration || decision.hasApprovedOwnedService
      {
        issues.append("\(decision.id.rawValue) must not claim an approved service or network transport")
      }
      if !decision.networkEndpoints.isEmpty {
        issues.append("\(decision.id.rawValue) must not name network endpoints while excluded")
      }
      if decision.dataFlow.isEmpty
        || !decision.dataFlow.contains(where: {
          $0.description.localizedCaseInsensitiveContains("leave the device")
        })
      {
        issues.append("\(decision.id.rawValue) must document the local-only data flow")
      }
      if decision.excludedCapabilities.isEmpty || decision.securityRequirements.isEmpty
        || decision.prerequisites.isEmpty || decision.completionObligations.isEmpty
        || decision.reEvaluationTriggers.isEmpty || decision.disclosure.isEmpty
        || decision.decisionDocumentPath.isEmpty
      {
        issues.append("\(decision.id.rawValue) must fill every decision-document section")
      }
      if decision.recordVersion <= 0 || decision.decisionDate.isEmpty {
        issues.append("\(decision.id.rawValue) must carry a record version and date")
      }
    }
    return issues
  }
}
