import Foundation
import PDFCore
@testable import PDFEditing
import Testing

@Suite("Optional expansion and linked-flow scope decisions")
struct ScopeEnhancementTests {
  // MARK: SCOPE-07

  @Test func aiAndDesignGenerationAreDeferredOptionalExpansions() {
    #expect(OptionalExpansionFeature.allCases.count == 2)
    for decision in OptionalExpansionScope.decisions {
      #expect(decision.status == .deferredOptionalExpansion)
      #expect(decision.status != .notBaseline)
      #expect(decision.requiresNetwork == false)
      #expect(decision.requiresCitations)
      #expect(decision.requiresReviewableEdits)
      #expect(!decision.acceptanceCriteria.isEmpty)
      #expect(decision.dataHandling.contains("opt-in") || decision.dataHandling.contains("explicit user action"))
      #expect(decision.disclosure.contains("Not implemented in this build"))
    }
    #expect(OptionalExpansionScope.baselineStatement.contains("independent"))
    #expect(OptionalExpansionScope.baselineStatement.contains("never delay"))
    #expect(OptionalExpansionScope.noHiddenDataStatement.contains("no network"))
    let report = OptionalExpansionScope.report()
    #expect(report.contains("SCOPE-07 optional expansion decision record"))
    #expect(report.contains("aiAnalysis"))
    #expect(report.contains("spacesDesignGeneration"))
    #expect(report.contains("no silent upload") || report.contains("No background upload"))
    let analysis = OptionalExpansionScope.decision(for: .aiAnalysis)
    #expect(analysis.acceptanceCriteria.contains { $0.contains("no-network default") })
    let design = OptionalExpansionScope.decision(for: .spacesDesignGeneration)
    #expect(design.acceptanceCriteria.contains { $0.contains("clearly labelled") })
  }

  // MARK: SCOPE-08

  @Test func linkedFlowIsDeferredWithExistingBaselinePrimitivesPreserved() {
    let decision = LinkedFlowScope.decision
    #expect(decision.status.contains("deferred"))
    #expect(decision.baselinePrimitives.contains { $0.contains("ParagraphCrossPage") })
    #expect(decision.baselinePrimitives.contains { $0.contains("ParagraphReflow") })
    #expect(decision.baselinePrimitives.contains { $0.contains("independent boxes") })
    #expect(decision.adobeBaselineFact.contains("without automatic cross-page reflow"))
    #expect(decision.adobeBaselineFact.contains("not baseline"))
    #expect(decision.futureModelContract.contains { $0.contains("explicit authored link") })
    #expect(decision.futureModelContract.contains { $0.contains("Reading order is stable") })
    #expect(decision.futureModelContract.contains { $0.contains("Undo") })
    #expect(decision.disclosure.contains("does not implement automatic cross-page reflow"))
    #expect(decision.report().contains("SCOPE-08 linked-flow decision"))
    #expect(LinkedFlowScope.report().contains("No Acrobat baseline parity"))
  }

  @Test func authoredFlowModelContractValidatesStableOrderedLinks() throws {
    let model = AuthoredFlowModel(links: [
      AuthoredFlowLink(
        sourcePageIndex: 0, sourceParagraphIndex: 0,
        targetPageIndex: 1, targetParagraphIndex: 0, readingOrder: 0),
      AuthoredFlowLink(
        sourcePageIndex: 1, sourceParagraphIndex: 0,
        targetPageIndex: 2, targetParagraphIndex: 0, readingOrder: 1),
    ])
    let validated = try model.validated()
    #expect(validated == model)
    #expect(model.report().contains("page 1 box 1 -> page 2 box 1"))
    #expect(model.report().contains("No Acrobat baseline parity"))
  }

  @Test func authoredFlowModelRejectsAmbiguousOrBrokenChains() {
    #expect(throws: AuthoredFlowModel.ValidationError.self) {
      _ = try AuthoredFlowModel(links: []).validated()
    }
    let duplicateOrder = AuthoredFlowModel(links: [
      AuthoredFlowLink(sourcePageIndex: 0, sourceParagraphIndex: 0,
        targetPageIndex: 1, targetParagraphIndex: 0, readingOrder: 0),
      AuthoredFlowLink(sourcePageIndex: 1, sourceParagraphIndex: 0,
        targetPageIndex: 2, targetParagraphIndex: 0, readingOrder: 0),
    ])
    #expect(throws: AuthoredFlowModel.ValidationError.duplicateReadingOrder) {
      _ = try duplicateOrder.validated()
    }
    let nonIncreasing = AuthoredFlowModel(links: [
      AuthoredFlowLink(sourcePageIndex: 0, sourceParagraphIndex: 0,
        targetPageIndex: 1, targetParagraphIndex: 0, readingOrder: 1),
    ])
    #expect(throws: AuthoredFlowModel.ValidationError.nonIncreasingReadingOrder) {
      _ = try nonIncreasing.validated()
    }
    let selfLink = AuthoredFlowModel(links: [
      AuthoredFlowLink(sourcePageIndex: 0, sourceParagraphIndex: 0,
        targetPageIndex: 0, targetParagraphIndex: 0, readingOrder: 0),
    ])
    #expect(throws: AuthoredFlowModel.ValidationError.selfLink) {
      _ = try selfLink.validated()
    }
    let gap = AuthoredFlowModel(links: [
      AuthoredFlowLink(sourcePageIndex: 0, sourceParagraphIndex: 0,
        targetPageIndex: 1, targetParagraphIndex: 0, readingOrder: 0),
      AuthoredFlowLink(sourcePageIndex: 3, sourceParagraphIndex: 0,
        targetPageIndex: 4, targetParagraphIndex: 0, readingOrder: 1),
    ])
    #expect(throws: AuthoredFlowModel.ValidationError.readingOrderGap) {
      _ = try gap.validated()
    }
  }
}
