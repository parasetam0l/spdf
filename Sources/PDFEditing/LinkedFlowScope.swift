import Foundation
import PDFCore

/// SCOPE-08: linked boxes and automatic cross-page reflow remain an optional
/// authored-flow enhancement. The existing bounded, explicitly declared
/// cross-page primitives stay baseline-supported and are not relabelled as a
/// missing Adobe feature. This file records the decision and a proposed,
/// contract-only authored-flow model; it deliberately contains no automatic
/// reflow engine and no Undo claim for the deferred enhancement.
public struct AuthoredFlowLink: Sendable, Equatable {
  public let sourcePageIndex: Int
  public let sourceParagraphIndex: Int
  public let targetPageIndex: Int
  public let targetParagraphIndex: Int
  public let readingOrder: Int

  public init(
    sourcePageIndex: Int, sourceParagraphIndex: Int, targetPageIndex: Int,
    targetParagraphIndex: Int, readingOrder: Int
  ) {
    self.sourcePageIndex = sourcePageIndex
    self.sourceParagraphIndex = sourceParagraphIndex
    self.targetPageIndex = targetPageIndex
    self.targetParagraphIndex = targetParagraphIndex
    self.readingOrder = readingOrder
  }
}

public struct AuthoredFlowModel: Sendable, Equatable {
  public let links: [AuthoredFlowLink]

  public init(links: [AuthoredFlowLink]) {
    self.links = links
  }

  public enum ValidationError: Error, Equatable {
    case emptyModel
    case duplicateReadingOrder
    case nonIncreasingReadingOrder
    case duplicateSource
    case duplicateTarget
    case selfLink
    case readingOrderGap
  }

  /// Contract-only validation for the deferred enhancement. It checks that
  /// explicit links are ordered, unique and acyclic by construction (links form
  /// a single forward chain); it does not execute any overflow.
  public func validated() throws -> AuthoredFlowModel {
    guard !links.isEmpty else { throw ValidationError.emptyModel }
    let ordered = links.sorted { $0.readingOrder < $1.readingOrder }
    var seenOrders: Set<Int> = []
    var seenSources: Set<String> = []
    var seenTargets: Set<String> = []
    var previousTarget: String?
    for (index, link) in ordered.enumerated() {
      let sourceKey = String(link.sourcePageIndex) + "/" + String(link.sourceParagraphIndex)
      let targetKey = String(link.targetPageIndex) + "/" + String(link.targetParagraphIndex)
      guard seenOrders.insert(link.readingOrder).inserted else {
        throw ValidationError.duplicateReadingOrder
      }
      guard link.readingOrder == index else { throw ValidationError.nonIncreasingReadingOrder }
      guard sourceKey != targetKey else { throw ValidationError.selfLink }
      guard seenSources.insert(sourceKey).inserted else { throw ValidationError.duplicateSource }
      guard seenTargets.insert(targetKey).inserted else { throw ValidationError.duplicateTarget }
      if let previousTarget, previousTarget != sourceKey {
        throw ValidationError.readingOrderGap
      }
      previousTarget = targetKey
    }
    return self
  }

  public func report() -> String {
    let ordered = links.sorted { $0.readingOrder < $1.readingOrder }
    var lines = ["Authored flow model contract — " + String(ordered.count) + " link(s)"]
    for link in ordered {
      lines.append(
        "  " + String(link.readingOrder) + ": page " + String(link.sourcePageIndex + 1)
          + " box " + String(link.sourceParagraphIndex + 1) + " -> page "
          + String(link.targetPageIndex + 1) + " box " + String(link.targetParagraphIndex + 1))
    }
    lines.append(LinkedFlowScope.decision.disclosure)
    return lines.joined(separator: "\n")
  }
}

public struct LinkedFlowScopeDecision: Sendable, Equatable {
  public let status: String
  public let baselinePrimitives: [String]
  public let adobeBaselineFact: String
  public let futureModelContract: [String]
  public let disclosure: String

  public func report() -> String {
    var lines = ["SCOPE-08 linked-flow decision — " + status]
    for primitive in baselinePrimitives { lines.append("  Baseline primitive: " + primitive) }
    lines.append("  Adobe baseline: " + adobeBaselineFact)
    for item in futureModelContract { lines.append("  Optional contract: " + item) }
    lines.append("  " + disclosure)
    return lines.joined(separator: "\n")
  }
}

public enum LinkedFlowScope {
  public static let decision = LinkedFlowScopeDecision(
    status: "deferred optional enhancement (contract recorded; no engine)",
    baselinePrimitives: [
      "ParagraphCrossPage: fill explicitly declared region boxes across pages in order",
      "ParagraphReflow: bounded edits and explicit overflow policy",
      "cross-page text selection/copy and text-box paste (independent boxes, no automatic links)",
    ],
    adobeBaselineFact:
      "Adobe documents independent text boxes without automatic cross-page reflow; a linked-box "
      + "flow model is not baseline Acrobat Pro behavior and must not be presented as missing baseline.",
    futureModelContract: [
      "Every overflow transition has an explicit authored link between named page boxes.",
      "Reading order is stable and validated (ordered, unique, no cycles, no implicit links).",
      "Applying the plan is an edit with Undo/Redo; preview and verification are separate.",
      "Existing bounded ParagraphCrossPage/ParagraphReflow primitives remain supported unchanged.",
      "The enhancement has its own acceptance tests and never blocks baseline flows.",
    ],
    disclosure:
      "This build keeps the bounded explicit-region primitives and the contract above; it does "
      + "not implement automatic cross-page reflow, implicit links or Undo for a deferred engine. "
      + "No Acrobat baseline parity is claimed for linked boxes."
  )

  public static func report() -> String { decision.report() }
}
