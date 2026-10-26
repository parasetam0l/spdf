import Foundation

/// REL-05: owner workflow acceptance and public-help accuracy.
///
/// Owner acceptance is an owner action; this type records and validates it, it
/// cannot grant it. Public claims are checked against the shipped selector
/// inventory so help text cannot promise an unexposed core helper, and every
/// chosen workflow must carry an explicit owner acceptance reference before the
/// record can be accepted.
public enum WorkflowAcceptanceStatus: String, Codable, Sendable, CaseIterable {
  case ownerAccepted
  case pendingOwner
  case excluded
  case notRun

  public var displayName: String {
    switch self {
    case .ownerAccepted: return "Owner accepted"
    case .pendingOwner: return "Pending owner"
    case .excluded: return "Excluded from this release"
    case .notRun: return "Not run"
    }
  }
}

public struct WorkflowAcceptance: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var workflow: String
  public var status: WorkflowAcceptanceStatus
  /// Owner sign-off reference (date, message, acceptance log). Required for
  /// ownerAccepted; never synthesized here.
  public var ownerReference: String
  /// Required for excluded workflows.
  public var exclusionReason: String
  /// Menu selectors/operations this workflow uses; must exist in the inventory.
  public var selectors: [String]

  public init(
    id: String, workflow: String, status: WorkflowAcceptanceStatus,
    ownerReference: String = "", exclusionReason: String = "", selectors: [String] = []
  ) {
    self.id = id
    self.workflow = workflow
    self.status = status
    self.ownerReference = ownerReference
    self.exclusionReason = exclusionReason
    self.selectors = selectors
  }
}

/// One public help/claim sentence with the implementation symbols it promises.
public struct HelpClaim: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var document: String
  public var claim: String
  /// Symbols the sentence names directly (for example a core helper name).
  public var referencedSymbols: [String]
  /// Shipped selectors/operations that actually implement the claim.
  public var backingSelectors: [String]
  /// Where the claim was reviewed (commit, doc version, review log).
  public var reviewReference: String

  public init(
    id: String, document: String, claim: String, referencedSymbols: [String] = [],
    backingSelectors: [String] = [], reviewReference: String = ""
  ) {
    self.id = id
    self.document = document
    self.claim = claim
    self.referencedSymbols = referencedSymbols
    self.backingSelectors = backingSelectors
    self.reviewReference = reviewReference
  }
}

public struct OwnerAcceptanceInput: Sendable, Equatable {
  public var appVersion: String
  public var sourceSHA: String
  public var workflows: [WorkflowAcceptance]
  public var helpClaims: [HelpClaim]
  /// Menu selectors and operations the shipped app exposes.
  public var exposedSelectors: [String]
  /// Core helpers that public help may mention only if they stay internal; by
  /// default such references are treated as unexposed promises.
  public var approvedCoreReferences: [String]
  public var knownExceptions: [String]

  public init(
    appVersion: String, sourceSHA: String, workflows: [WorkflowAcceptance],
    helpClaims: [HelpClaim], exposedSelectors: [String],
    approvedCoreReferences: [String] = [], knownExceptions: [String] = []
  ) {
    self.appVersion = appVersion
    self.sourceSHA = sourceSHA
    self.workflows = workflows
    self.helpClaims = helpClaims
    self.exposedSelectors = exposedSelectors
    self.approvedCoreReferences = approvedCoreReferences
    self.knownExceptions = knownExceptions
  }
}

public enum AcceptanceCheckStatus: String, Codable, Sendable, Equatable {
  case passed
  case failed
  case pendingOwner
  case notRun
}

public struct AcceptanceCheck: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var title: String
  public var status: AcceptanceCheckStatus
  public var detail: String
  public var evidenceReference: String

  public init(
    id: String, title: String, status: AcceptanceCheckStatus, detail: String,
    evidenceReference: String = ""
  ) {
    self.id = id
    self.title = title
    self.status = status
    self.detail = detail
    self.evidenceReference = evidenceReference
  }
}

public struct OwnerAcceptanceReport: Codable, Sendable, Equatable {
  public enum Verdict: String, Codable, Sendable {
    case ownerAccepted
    case pendingOwner
    case blocked
  }

  public static let claimStatement =
    "This record validates an owner acceptance that the owner performed; it does not "
    + "grant acceptance, cannot exercise the app, and never converts pending owner work "
    + "into a pass. Public claim checks compare help text with the shipped selector "
    + "inventory so help cannot promise an unexposed core helper."

  public static let notClaimed: [String] = [
    "Performing owner workflow acceptance (owner action).",
    "Independent usability or accessibility testing of the interface.",
    "Claims about releases other than the version and source SHA recorded here.",
    "Acrobat replacement or a percentage score.",
  ]

  public let checks: [AcceptanceCheck]
  public let verdict: Verdict
  public let issues: [String]

  public init(input: OwnerAcceptanceInput) {
    var checks: [AcceptanceCheck] = []
    var issues: [String] = []

    let exposed = Set(input.exposedSelectors)
    let approved = Set(input.approvedCoreReferences)

    // 1. Identity of the shipped release.
    let cleanSHA = input.sourceSHA.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let versionOK = !input.appVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let shaOK = cleanSHA.count >= 40 && cleanSHA.allSatisfy({ $0.isHexDigit })
    checks.append(
      AcceptanceCheck(
        id: "release-identity",
        title: "Acceptance is bound to one shipped release",
        status: versionOK && shaOK ? .passed : .failed,
        detail: versionOK && shaOK
          ? "Version " + input.appVersion + " at " + cleanSHA + "."
          : "A non-empty version and a full hexadecimal source SHA are required.",
        evidenceReference: versionOK && shaOK ? cleanSHA : ""))

    // 2. Every chosen workflow needs explicit owner acceptance.
    if input.workflows.isEmpty {
      checks.append(
        AcceptanceCheck(
          id: "workflow-matrix", title: "Chosen workflows have owner acceptance",
          status: .notRun, detail: "No workflow acceptance rows were recorded."))
      issues.append("No workflow rows; owner acceptance cannot be inferred.")
    } else {
      for workflow in input.workflows {
        switch workflow.status {
        case .ownerAccepted:
          let reference = workflow.ownerReference.trimmingCharacters(
            in: .whitespacesAndNewlines)
          if reference.isEmpty {
            checks.append(
              AcceptanceCheck(
                id: "workflow-" + workflow.id,
                title: "Owner acceptance: " + workflow.workflow, status: .failed,
                detail: "ownerAccepted requires an owner sign-off reference."))
            issues.append("Workflow \(workflow.id) claims owner acceptance without a reference")
          } else {
            checks.append(
              AcceptanceCheck(
                id: "workflow-" + workflow.id,
                title: "Owner acceptance: " + workflow.workflow, status: .passed,
                detail: "Owner accepted the workflow.", evidenceReference: reference))
          }
        case .pendingOwner:
          checks.append(
            AcceptanceCheck(
              id: "workflow-" + workflow.id,
              title: "Owner acceptance: " + workflow.workflow, status: .pendingOwner,
              detail: "The owner has not yet accepted this workflow."))
          issues.append("Workflow \(workflow.id) is still pending owner acceptance")
        case .excluded:
          let reason = workflow.exclusionReason.trimmingCharacters(in: .whitespacesAndNewlines)
          if reason.isEmpty {
            checks.append(
              AcceptanceCheck(
                id: "workflow-" + workflow.id,
                title: "Workflow excluded: " + workflow.workflow, status: .failed,
                detail: "An excluded workflow needs a reason known to users."))
            issues.append("Workflow \(workflow.id) is excluded without a reason")
          } else {
            checks.append(
              AcceptanceCheck(
                id: "workflow-" + workflow.id,
                title: "Workflow excluded: " + workflow.workflow, status: .passed,
                detail: reason))
          }
        case .notRun:
          checks.append(
            AcceptanceCheck(
              id: "workflow-" + workflow.id,
              title: "Workflow acceptance: " + workflow.workflow, status: .notRun,
              detail: "The workflow has not been exercised for acceptance."))
          issues.append("Workflow \(workflow.id) was not run")
        }
        let missing = workflow.selectors.filter { !exposed.contains($0) }
        if !missing.isEmpty {
          issues.append(
            "Workflow \(workflow.id) names selectors that are not in the shipped inventory: "
              + missing.sorted().joined(separator: ", "))
          checks.append(
            AcceptanceCheck(
              id: "workflow-inventory-" + workflow.id,
              title: "Workflow uses shipped selectors: " + workflow.workflow,
              status: .failed,
              detail: "Selectors absent from the shipped inventory: "
                + missing.sorted().joined(separator: ", ")))
        }
      }
    }

    // 3. Help claims: no unexposed helper promises, every claim has backing.
    if input.helpClaims.isEmpty {
      checks.append(
        AcceptanceCheck(
          id: "help-claims", title: "Public help claims match shipped implementation",
          status: .notRun, detail: "No public help claims were supplied for review."))
      issues.append("No public help claims were reviewed")
    } else {
      for claim in input.helpClaims {
        var failures: [String] = []
        let unexposedSymbols = claim.referencedSymbols.filter {
          !exposed.contains($0) && !approved.contains($0)
        }
        if !unexposedSymbols.isEmpty {
          failures.append(
            "names unexposed helper(s): " + unexposedSymbols.sorted().joined(separator: ", "))
        }
        if claim.backingSelectors.isEmpty {
          failures.append("has no shipped backing selector")
        }
        let missingBacking = claim.backingSelectors.filter { !exposed.contains($0) }
        if !missingBacking.isEmpty {
          failures.append(
            "backs onto selectors absent from the shipped inventory: "
              + missingBacking.sorted().joined(separator: ", "))
        }
        let review = claim.reviewReference.trimmingCharacters(in: .whitespacesAndNewlines)
        if review.isEmpty {
          failures.append("was not reviewed with a reference")
        }
        if failures.isEmpty {
          checks.append(
            AcceptanceCheck(
              id: "help-" + claim.id,
              title: "Help claim: " + claim.document, status: .passed,
              detail: "Backed by shipped selectors: "
                + claim.backingSelectors.sorted().joined(separator: ", ") + ".",
              evidenceReference: review))
        } else {
          checks.append(
            AcceptanceCheck(
              id: "help-" + claim.id,
              title: "Help claim: " + claim.document, status: .failed,
              detail: "The claim " + failures.joined(separator: "; ") + "."))
          issues.append("Help claim \(claim.id) is not supported: " + failures.joined(separator: "; "))
        }
      }
    }

    // 4. Known exceptions are attached, not hidden.
    if !input.knownExceptions.isEmpty {
      let empty = input.knownExceptions.filter {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      checks.append(
        AcceptanceCheck(
          id: "known-exceptions", title: "Known exceptions are disclosed",
          status: empty.isEmpty ? .passed : .failed,
          detail: empty.isEmpty
            ? "\(input.knownExceptions.count) exception(s) attached to the acceptance record."
            : "An empty known-exception entry was supplied."))
    }

    let failed = checks.filter { $0.status == .failed }
    let pending = checks.filter { $0.status == .pendingOwner }
    let notRun = checks.filter { $0.status == .notRun }
    let verdict: Verdict
    if !failed.isEmpty {
      verdict = .blocked
    } else if !pending.isEmpty || !notRun.isEmpty {
      verdict = .pendingOwner
    } else {
      verdict = .ownerAccepted
    }
    self.checks = checks
    self.verdict = verdict
    self.issues = issues
  }

  public var isOwnerAccepted: Bool { verdict == .ownerAccepted }
  public var failedChecks: [AcceptanceCheck] { checks.filter { $0.status == .failed } }

  public func markdown() -> String {
    var lines = [
      "# Owner acceptance and help accuracy (REL-05)", "",
      OwnerAcceptanceReport.claimStatement, "",
      "Verdict: \(verdict.rawValue)",
      "",
      "| Check | Status | Evidence | Detail |",
      "| --- | --- | --- | --- |",
    ]
    for check in checks {
      lines.append(
        "| \(check.title) | \(check.status.rawValue) | "
          + "\(check.evidenceReference.isEmpty ? "—" : check.evidenceReference) | "
          + "\(check.detail) |")
    }
    if !issues.isEmpty {
      lines.append("")
      lines.append("## Record issues")
      for issue in issues { lines.append("- " + issue) }
    }
    lines.append("")
    lines.append("## Not claimed")
    for item in OwnerAcceptanceReport.notClaimed { lines.append("- " + item) }
    return lines.joined(separator: "\n")
  }

  public func jsonData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    return try encoder.encode(self)
  }
}
