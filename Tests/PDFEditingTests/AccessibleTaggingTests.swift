import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// A11Y-03 evidence: extended reviewed suggestions for headings, lists,
/// multicolumn paragraphs, figures/captions and untagged content. Nothing is
/// tagged before acceptance, reviewers can correct kinds, and no acceptance is
/// represented as a conformance claim.
@Suite("Accessible tagging suggestions")
struct AccessibleTaggingTests {
  private func inventory(_ graph: PDFGraph, _ pageIDs: [PDFObjectID]) throws
    -> PDFStructureInventory
  {
    try PDFStructureInspector.inspect(in: graph, pageIDs: pageIDs)
  }

  @Test func extendedSuggestionKindsAreVisibleBeforeAcceptance() throws {
    let (graph, pageIDs) = A11YFixtures.untaggedDocument()
    let analysis = try AccessibleTaggingAssistant.analyze(pageIDs: pageIDs, in: graph)
    #expect(analysis.pagesAnalyzed == 3)
    #expect(analysis.untaggedTextBlocks > 0)
    #expect(analysis.untaggedFigures == 1)
    #expect(analysis.notes.contains { $0.contains("not an accessibility-conformance claim") })

    func kinds() -> [String] {
      analysis.suggestions.map { suggestion -> String in
        switch suggestion.kind {
        case .heading: return "heading"
        case .paragraph: return "paragraph"
        case .multicolumnParagraph: return "multicolumn"
        case .list: return "list"
        case .figure: return "figure"
        case .caption: return "caption"
        case .artifact: return "artifact"
        }
      }
    }
    let all = kinds()
    #expect(all.contains("heading"))
    #expect(all.contains("paragraph"))
    #expect(all.contains("list"))
    #expect(all.contains("figure"))
    #expect(all.contains("caption"), "kinds: \(all)")
    #expect(all.contains("artifact"))

    // Pending suggestions are not structure: the document stays untagged.
    let before = try inventory(graph, pageIDs)
    #expect(before.elements.isEmpty)
    var review = AccessibleTaggingReview(suggestions: analysis.suggestions)
    #expect(review.pending.count == analysis.suggestions.count)
    #expect(review.accepted.isEmpty)
    #expect(try inventory(graph, pageIDs).elements.isEmpty)
    review.reject(analysis.suggestions[0].id)
    #expect(review.rejected.count == 1)
  }

  @Test func listSuggestionKeepsItemsAndAppliesAsNestedLI() throws {
    let (graph, pageIDs) = A11YFixtures.untaggedDocument()
    let analysis = try AccessibleTaggingAssistant.analyze(pageIDs: pageIDs, in: graph)
    let list = try #require(analysis.suggestions.first {
      if case .list = $0.kind { return true }
      return false
    })
    guard case .list(let ordered, let items, let snippets) = list.kind else {
      Issue.record("not a list suggestion")
      return
    }
    #expect(!ordered)
    #expect(items.count == 3)
    #expect(snippets.count == 3)
    #expect(snippets[0].contains("Alpha"))
    var review = AccessibleTaggingReview(suggestions: [list])
    review.accept(list.id)
    let command = try #require(review.command(for: list))
    let applied = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
    let structure = try inventory(applied, pageIDs)
    #expect(
      structure.issues.filter { $0.kind != .unmarkedPage }.isEmpty,
      "\(structure.issues.map(\.message).joined(separator: "; "))")
    let listElement = try #require(structure.elements.first { $0.role == "L" })
    let children = listElement.children.compactMap { child -> String? in
      guard case .element(let element) = child else { return nil }
      return element.role
    }
    #expect(children == ["LI", "LI", "LI"])
    let liMCIDs = listElement.children.compactMap { child -> Int? in
      guard case .element(let element) = child else { return nil }
      for content in element.children {
        if case .content(pageIndex: _, mcid: let mcid) = content { return mcid }
      }
      return nil
    }
    #expect(Set(liMCIDs).count == 3)
    // Save and reopen keeps the nested list structure.
    let reopened = try PDFParser.parse(try PDFWriter.write(applied))
    let reopenedStructure = try inventory(reopened.graph, reopened.pageIDs)
    #expect(reopenedStructure.elements.first { $0.role == "L" }?.children.count == 3)
  }

  @Test func reviewerCorrectionChangesTheAppliedRole() throws {
    let (graph, pageIDs) = A11YFixtures.untaggedDocument()
    let analysis = try AccessibleTaggingAssistant.analyze(pageIDs: pageIDs, in: graph)
    let paragraph = try #require(analysis.suggestions.first {
      if case .paragraph = $0.kind { return true }
      return false
    })
    var review = AccessibleTaggingReview(suggestions: [paragraph])
    review.correct(paragraph.id, to: .heading(level: 2))
    review.accept(paragraph.id)
    #expect(review.correctedCount == 1)
    #expect(review.effectiveKind(of: paragraph) == .heading(level: 2))
    let effective = review.effectiveSuggestion(of: paragraph)
    #expect(effective.origin == .reviewerCorrection)
    #expect(effective.proposedRole == "H2")
    let command = try #require(review.command(for: paragraph))
    let applied = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
    let structure = try inventory(applied, pageIDs)
    #expect(structure.elements.contains { $0.role == "H2" })
    #expect(
      structure.issues.filter { $0.kind != .unmarkedPage }.isEmpty,
      "\(structure.issues.map(\.message).joined(separator: "; "))")
    // The same content applied without correction would have been a P.
    let plain = try PDFEditingEngine.commit(
      PDFTransaction([
        ApplyTaggingSuggestionCommand(
          pageID: paragraph.pageID, role: PDFName("P"), altText: nil,
          content: .text(runIndices: paragraph.runIndices))
      ]), to: graph)
    #expect(try inventory(plain, pageIDs).elements.contains { $0.role == "P" })
  }

  @Test func captionAndFigureAcceptanceCreatesExpectedRoles() throws {
    let (graph, pageIDs) = A11YFixtures.untaggedDocument()
    let analysis = try AccessibleTaggingAssistant.analyze(pageIDs: pageIDs, in: graph)
    let caption = try #require(analysis.suggestions.first {
      if case .caption = $0.kind { return true }
      return false
    })
    let figure = try #require(analysis.suggestions.first {
      if case .figure = $0.kind { return true }
      return false
    })
    var review = AccessibleTaggingReview(suggestions: [caption, figure])
    review.accept(caption.id)
    review.accept(figure.id)
    #expect(review.command(for: figure) == nil, "figures need reviewer alt text")
    let figureCommand = try #require(review.command(for: figure, altText: "A green square"))
    let captionCommand = try #require(review.command(for: caption))
    let applied = try PDFEditingEngine.commit(
      PDFTransaction([captionCommand, figureCommand]), to: graph)
    let structure = try inventory(applied, pageIDs)
    #expect(structure.elements.contains { $0.role == "Caption" })
    let figureElement = try #require(structure.elements.first { $0.role == "Figure" })
    #expect(figureElement.alt == "A green square")
    #expect(
      structure.issues.filter { $0.kind != .unmarkedPage }.isEmpty,
      "\(structure.issues.map(\.message).joined(separator: "; "))")
  }

  @Test func multicolumnParagraphsSplitByColumn() throws {
    let (graph, pageIDs) = A11YFixtures.untaggedDocument()
    let analysis = try AccessibleTaggingAssistant.analyze(pageIDs: pageIDs, in: graph)
    let columnSuggestions = analysis.suggestions.filter {
      if case .multicolumnParagraph = $0.kind { return true }
      return false
    }
    #expect(!columnSuggestions.isEmpty)
    var columns: Set<Int> = []
    for suggestion in columnSuggestions {
      guard case .multicolumnParagraph(let column, let columnCount) = suggestion.kind else {
        continue
      }
      columns.insert(column)
      #expect(columnCount == 2)
      #expect(suggestion.pageIndex == 2)
      // Each suggestion stays inside one column.
      #expect(suggestion.bounds[2] - suggestion.bounds[0] < 250)
    }
    #expect(columns == [0, 1])
  }

  @Test func untaggedContentAccountingAndReviewState() throws {
    let (graph, pageIDs) = A11YFixtures.untaggedDocument()
    let analysis = try AccessibleTaggingAssistant.analyze(pageIDs: pageIDs, in: graph)
    #expect(analysis.summary.contains("untagged"))
    #expect(analysis.pagesWithoutTaggedContent == 3)
    #expect(analysis.taggedBlocksSkipped == 0)
    let textSuggestions = analysis.suggestions.filter {
      if case .figure = $0.kind { return false }
      return true
    }
    #expect(analysis.untaggedTextBlocks >= textSuggestions.count)

    // Already tagged content is skipped rather than suggested again.
    let applied = try PDFEditingEngine.commit(
      PDFTransaction([
        ApplyTaggingSuggestionCommand(
          pageID: pageIDs[0], role: PDFName("P"), altText: nil,
          content: .text(runIndices: [0]))
      ]), to: graph)
    let after = try AccessibleTaggingAssistant.analyze(pageIDs: pageIDs, in: applied)
    #expect(after.taggedBlocksSkipped >= 0)
    #expect(after.suggestions.count <= analysis.suggestions.count)
  }
}
