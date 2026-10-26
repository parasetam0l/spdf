import Foundation

/// SCOPE-07: AI/Spaces/design generation are optional expansion decisions, not
/// baseline Acrobat Pro desktop replacement requirements. The chosen scope is
/// "deferred, no local or service implementation": no model, network call,
/// telemetry or design generator is added here. This decision record defines the
/// acceptance conditions any future optional feature must meet.
public enum OptionalExpansionFeature: String, Sendable, Equatable, CaseIterable {
  case aiAnalysis
  case spacesDesignGeneration
}

public enum OptionalExpansionStatus: String, Sendable, Equatable {
  case deferredOptionalExpansion
  case notBaseline
}

public struct OptionalExpansionDecision: Sendable, Equatable {
  public let feature: OptionalExpansionFeature
  public let status: OptionalExpansionStatus
  public let executionMode: String
  public let requiresNetwork: Bool
  public let requiresCitations: Bool
  public let requiresReviewableEdits: Bool
  public let dataHandling: String
  public let acceptanceCriteria: [String]
  public let disclosure: String

  public func report() -> String {
    var lines = [
      "Optional expansion: " + feature.rawValue + " — " + status.rawValue
    ]
    lines.append("  Execution mode: " + executionMode)
    lines.append("  Network required: " + String(requiresNetwork))
    lines.append("  Citations: " + String(requiresCitations)
      + "; reviewable edits: " + String(requiresReviewableEdits))
    lines.append("  Data handling: " + dataHandling)
    for criterion in acceptanceCriteria { lines.append("  Acceptance: " + criterion) }
    lines.append("  " + disclosure)
    return lines.joined(separator: "\n")
  }
}

public enum OptionalExpansionScope {
  public static let baselineStatement =
    "Ordinary Acrobat Pro desktop replacement scope is independent of AI/design "
    + "generation. A deferred optional feature must never delay or gate baseline "
    + "editing, preflight, print, accessibility, security or review work."

  public static let noHiddenDataStatement =
    "No AI/design feature is enabled in this build: no model runs locally, no network "
    + "request is made, and local/private document content is never sent to a service. "
    + "If a future optional feature is approved, it must declare its local or explicit "
    + "service path, citations, reviewable edits and data handling before shipping."

  public static func decision(for feature: OptionalExpansionFeature) -> OptionalExpansionDecision {
    switch feature {
    case .aiAnalysis:
      return OptionalExpansionDecision(
        feature: .aiAnalysis,
        status: .deferredOptionalExpansion,
        executionMode: "none (deferred); no local model or service call is implemented",
        requiresNetwork: false,
        requiresCitations: true,
        requiresReviewableEdits: true,
        dataHandling:
          "If later approved: local-only by default; any explicit-service mode must show "
          + "what is sent, require user opt-in per document and provide deletion/retention "
          + "controls. No background upload.",
        acceptanceCriteria: [
          "Analysis output cites the source page and extracted span it relies on.",
          "Every suggested edit is shown for review and applies only after explicit acceptance.",
          "The feature has its own independent acceptance tests, including a no-network default test.",
          "Opt-out must not affect baseline Acrobat Pro replacement workflows.",
        ],
        disclosure:
          "Not implemented in this build; this is a product-scope decision record, not a feature claim.")
    case .spacesDesignGeneration:
      return OptionalExpansionDecision(
        feature: .spacesDesignGeneration,
        status: .deferredOptionalExpansion,
        executionMode: "none (deferred); no design/generation service is implemented",
        requiresNetwork: false,
        requiresCitations: true,
        requiresReviewableEdits: true,
        dataHandling:
          "If later approved: explicit user action only, with a clear statement of generated "
          + "content and any document data shared to an approved service; no silent upload.",
        acceptanceCriteria: [
          "Generated design assets are clearly labelled as generated and cite their source inputs.",
          "Users can review, replace or discard every generated asset before it enters the document.",
          "The feature has independent acceptance tests and a visible data-sharing disclosure.",
          "Its absence never blocks baseline document editing/export.",
        ],
        disclosure:
          "Not implemented in this build; this is an optional expansion decision, not Studio feature parity.")
    }
  }

  public static var decisions: [OptionalExpansionDecision] {
    OptionalExpansionFeature.allCases.map(decision(for:))
  }

  public static func report() -> String {
    var lines = ["SCOPE-07 optional expansion decision record"]
    lines.append("Baseline: " + baselineStatement)
    lines.append("Data: " + noHiddenDataStatement)
    for decision in decisions { lines.append(decision.report()) }
    return lines.joined(separator: "\n")
  }
}
