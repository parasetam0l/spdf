import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// PAG-04 evidence: Replace Pages with an explicit retention matrix for
/// destination annotations, links, labels and form fields, and no dangling
/// references to removed page objects.
@Suite("Replace pages (PAG-04)")
struct ReplacePagesTests {
  // MARK: Fixtures

  private func commit(
    _ commands: [any PDFEditCommand], to graph: PDFGraph
  ) throws -> PDFGraph {
    try PDFEditingEngine.commit(PDFTransaction(commands), to: graph)
  }

  private struct PageVariant {
    let pageIndex: Int
    let text: String
  }

  private func makeVariant(
    pages: Int, prefix: String, highlights: [Int], links: [(page: Int, target: Int)],
    fields: [(page: Int, name: String)], labelsPrefix: String? = nil
  ) throws -> PDFGraph {
    var graph = PDFFixtures.graph(pages: pages)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    for index in 0..<pages {
      graph = try commit(
        [
          ReplaceTextCommand(
            pageID: pageIDs[index], runIndex: 0,
            replacement: "\(prefix)-\(index + 1)")
        ], to: graph)
    }
    for index in highlights {
      graph = try commit(
        [
          AddHighlightCommand(
            pageID: pageIDs[index],
            quads: [40, 730, 120, 730, 40, 710, 120, 710],
            contents: "\(prefix) highlight \(index + 1)", author: "Reviewer")
        ], to: graph)
    }
    for link in links {
      graph = try commit(
        [
          AddLinkCommand(
            pageID: pageIDs[link.page], rect: [40, 650, 140, 670],
            target: .page(link.target))
        ], to: graph)
    }
    for field in fields {
      graph = try commit(
        [
          AddTextFieldCommand(
            pageID: pageIDs[field.page], rect: [200, 500, 360, 524],
            name: field.name)
        ], to: graph)
    }
    if let labelsPrefix {
      try setPageLabels([(0, labelsPrefix)], in: &graph)
    }
    return graph
  }

  private func setPageLabels(
    _ ranges: [(startIndex: Int, prefix: String)], in graph: inout PDFGraph
  ) throws {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    else {
      Issue.record("Fixture catalog missing")
      return
    }
    var numbers: [PDFValue] = []
    for range in ranges {
      numbers.append(.integer(Int64(range.startIndex)))
      numbers.append(
        .dictionary([
          PDFName("S"): .name(PDFName("D")),
          PDFName("P"): .string(Data(range.prefix.utf8)),
        ]))
    }
    let labelsID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    graph.objects[labelsID] = .dictionary([PDFName("Nums"): .array(numbers)])
    catalog[PDFName("PageLabels")] = .reference(labelsID)
    graph.objects[catalogID] = .dictionary(catalog)
  }

  private func pageTexts(_ graph: PDFGraph) throws -> [String] {
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    return try pageIDs.map { pageID in
      let layout = try PageTextLayout.build(pageID: pageID, in: graph)
      return layout.lines.map { layout.text(in: $0) }.joined(separator: "\n")
    }
  }

  private func fieldNames(_ graph: PDFGraph) throws -> [String] {
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    return try FormInventory.fields(in: graph, pageIDs: pageIDs).map(\.name).sorted()
  }

  private func linkCount(_ graph: PDFGraph, pageIndex: Int) throws -> Int {
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let annotations = try AnnotationInventory.annotations(
      in: graph, pageID: pageIDs[pageIndex])
    return annotations.filter { $0.subtype == PDFName("Link") }.count
  }

  // MARK: Tests

  @Test func replacementMatrixAndOrderAreCorrect() throws {
    let destination = try makeVariant(
      pages: 3, prefix: "DEST", highlights: [0, 1], links: [(0, 1)],
      fields: [(0, "keepMe"), (1, "gone")], labelsPrefix: "D-")
    let source = try makeVariant(
      pages: 2, prefix: "SRC", highlights: [0, 1], links: [(0, 1)],
      fields: [(0, "keepMe"), (1, "added")])
    let sourceBytes = try PDFWriter.write(source, limits: PDFLimits())
    let destinationPageIDs = try PDFPageTree.pageIDs(in: destination)
    let sourcePageIDs = try PDFPageTree.pageIDs(in: source)
    #expect(sourcePageIDs.count == 2)
    let command = ReplacePagesCommand(
      sourceDocumentBytes: sourceBytes,
      destinationPageIDs: [destinationPageIDs[1]],
      sourcePageIndices: [0, 1],
      options: ReplacePagesOptions(
        formFieldConflicts: .rename, pageLabels: .retainDestination,
        structureTree: .dropDestination))
    let preview = try command.preflight(in: destination)
    let report = preview.report
    #expect(report.destinationPagesReplaced == 1)
    #expect(report.replacementPagesInserted == 2)
    #expect(report.destinationAnnotationsDropped >= 1)
    #expect(report.destinationLinksDropped >= 1)
    #expect(report.sourceAnnotationsImported == 2)
    #expect(report.sourceLinksImported >= 1)
    #expect(report.destinationFormFieldsRemoved.contains("gone"))
    #expect(report.sourceFormFieldsImported.contains("added"))
    #expect(!report.renamedFields.isEmpty)
    #expect(report.destinationPageLabelsRetained)
    let texts = try pageTexts(preview.graph)
    #expect(texts.count == 4)
    #expect(texts[0].contains("DEST-1"))
    #expect(texts[1].contains("SRC-1"))
    #expect(texts[2].contains("SRC-2"))
    #expect(texts[3].contains("DEST-3"))
    #expect(!texts.joined().contains("DEST-2"))
    // Retained destination labels remain positional; later labels shift.
    #expect(PDFPageLabels.label(forPageIndex: 0, in: preview.graph) == "D-1")
    #expect(PDFPageLabels.label(forPageIndex: 3, in: preview.graph) == "D-4")
    // The incoming link on a retained page to the removed page is dropped.
    let retainedLinks = try linkCount(preview.graph, pageIndex: 0)
    #expect(retainedLinks == 0)
    // Source fields survived as an AcroForm tree; collisions were renamed.
    let names = try fieldNames(preview.graph)
    #expect(names.contains("keepMe"))
    #expect(names.contains { $0.hasPrefix("keepMe_") || $0.hasPrefix("keepMe") && $0 != "keepMe" })
    #expect(names.contains("added"))
    #expect(!names.contains("gone"))
    // Full document round trip: no removed page text, valid parse.
    let data = try PDFWriter.write(preview.graph, limits: PDFLimits())
    #expect(data.range(of: Data("DEST-2".utf8)) == nil)
    let reparsed = try PDFParser.parse(data)
    let reparsedPages = try PDFPageTree.pageIDs(in: reparsed.graph)
    #expect(reparsedPages.count == 4)
    // Preview is non-mutating.
    let freshDestination = try makeVariant(
      pages: 3, prefix: "DEST", highlights: [0, 1], links: [(0, 1)],
      fields: [(0, "keepMe"), (1, "gone")], labelsPrefix: "D-")
    #expect(destination == freshDestination)
  }

  @Test func labelResetPolicyDropsDestinationLabels() throws {
    let destination = try makeVariant(
      pages: 2, prefix: "DEST", highlights: [], links: [], fields: [],
      labelsPrefix: "D-")
    let source = try makeVariant(
      pages: 1, prefix: "SRC", highlights: [], links: [], fields: [])
    let sourceBytes = try PDFWriter.write(source)
    let pageIDs = try PDFPageTree.pageIDs(in: destination)
    let command = ReplacePagesCommand(
      sourceDocumentBytes: sourceBytes, destinationPageIDs: [pageIDs[0]],
      sourcePageIndices: [0],
      options: ReplacePagesOptions(pageLabels: .reset))
    let result = try command.preflight(in: destination)
    #expect(!result.report.destinationPageLabelsRetained)
    #expect(PDFPageLabels.ranges(in: result.graph).isEmpty)
    #expect(PDFPageLabels.label(forPageIndex: 0, in: result.graph) == "1")
    let resetTexts = try pageTexts(result.graph)
    #expect(resetTexts[0].contains("SRC-1"))
  }

  @Test func structureTreePolicyRefusesOrDropsExplicitly() throws {
    let source = try makeVariant(
      pages: 1, prefix: "SRC", highlights: [], links: [], fields: [])
    let sourceBytes = try PDFWriter.write(source)
    let tagged = try PDFParser.parse(PDFFixtures.taggedPages())
    let taggedPages = try PDFPageTree.pageIDs(in: tagged.graph)
    let refusing = ReplacePagesCommand(
      sourceDocumentBytes: sourceBytes, destinationPageIDs: [taggedPages[0]],
      sourcePageIndices: [0],
      options: ReplacePagesOptions(structureTree: .refuseWhenPresent))
    #expect(throws: PDFError.self) {
      _ = try refusing.validate(in: tagged.graph)
    }
    let dropping = ReplacePagesCommand(
      sourceDocumentBytes: sourceBytes, destinationPageIDs: [taggedPages[0]],
      sourcePageIndices: [0],
      options: ReplacePagesOptions(structureTree: .dropDestination))
    let result = try dropping.preflight(in: tagged.graph)
    #expect(result.report.structureTreeDropped)
    #expect(ReplacePagesCommand.catalog(in: result.graph)?.dictionary[
      PDFName("StructTreeRoot")] == nil)
  }

  @Test func formFieldConflictPolicyCanRefuse() throws {
    let destination = try makeVariant(
      pages: 2, prefix: "DEST", highlights: [], links: [], fields: [(0, "keepMe")])
    let source = try makeVariant(
      pages: 1, prefix: "SRC", highlights: [], links: [], fields: [(0, "keepMe")])
    let sourceBytes = try PDFWriter.write(source)
    let pageIDs = try PDFPageTree.pageIDs(in: destination)
    let command = ReplacePagesCommand(
      sourceDocumentBytes: sourceBytes, destinationPageIDs: [pageIDs[1]],
      sourcePageIndices: [0],
      options: ReplacePagesOptions(formFieldConflicts: .refuse))
    #expect(throws: PDFError.self) {
      _ = try command.preflight(in: destination)
    }
    // With rename the duplicate is resolved explicitly.
    let renaming = ReplacePagesCommand(
      sourceDocumentBytes: sourceBytes, destinationPageIDs: [pageIDs[1]],
      sourcePageIndices: [0],
      options: ReplacePagesOptions(formFieldConflicts: .rename))
    let result = try renaming.preflight(in: destination)
    #expect(!result.report.renamedFields.isEmpty)
    let names = try fieldNames(result.graph)
    #expect(names.contains("keepMe"))
    #expect(names.count >= 2)
  }

  @Test func invalidSelectionsAndXFAareRefused() throws {
    let destination = try makeVariant(
      pages: 2, prefix: "DEST", highlights: [], links: [], fields: [])
    let source = try makeVariant(
      pages: 1, prefix: "SRC", highlights: [], links: [], fields: [])
    let sourceBytes = try PDFWriter.write(source)
    let pageIDs = try PDFPageTree.pageIDs(in: destination)
    #expect(throws: PDFError.self) {
      _ = try ReplacePagesCommand(
        sourceDocumentBytes: sourceBytes, destinationPageIDs: [],
        sourcePageIndices: [0]).validate(in: destination)
    }
    #expect(throws: PDFError.self) {
      _ = try ReplacePagesCommand(
        sourceDocumentBytes: sourceBytes, destinationPageIDs: [pageIDs[0]],
        sourcePageIndices: []).validate(in: destination)
    }
    #expect(throws: PDFError.self) {
      _ = try ReplacePagesCommand(
        sourceDocumentBytes: sourceBytes, destinationPageIDs: [pageIDs[0]],
        sourcePageIndices: [5]).validate(in: destination)
    }
    #expect(throws: PDFError.self) {
      _ = try ReplacePagesCommand(
        sourceDocumentBytes: sourceBytes,
        destinationPageIDs: [pageIDs[0], pageIDs[0]],
        sourcePageIndices: [0]).validate(in: destination)
    }
    // XFA destination data is refused instead of being silently dropped.
    guard case .reference(let catalogID)? = destination.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = destination.objects[catalogID]
    else {
      Issue.record("Fixture catalog missing")
      return
    }
    catalog[PDFName("AcroForm")] = .dictionary([
      PDFName("XFA"): .array([.string(Data("fake-xfa".utf8))])
    ])
    var xfaGraph = destination
    xfaGraph.objects[catalogID] = .dictionary(catalog)
    #expect(throws: PDFError.self) {
      _ = try ReplacePagesCommand(
        sourceDocumentBytes: sourceBytes, destinationPageIDs: [pageIDs[0]],
        sourcePageIndices: [0]).validate(in: xfaGraph)
    }
  }

  @Test func replaceAllPagesKeepsAValidDocument() throws {
    let destination = try makeVariant(
      pages: 1, prefix: "DEST", highlights: [0], links: [], fields: [])
    let source = try makeVariant(
      pages: 2, prefix: "SRC", highlights: [0], links: [], fields: [])
    let sourceBytes = try PDFWriter.write(source)
    let pageIDs = try PDFPageTree.pageIDs(in: destination)
    let command = ReplacePagesCommand(
      sourceDocumentBytes: sourceBytes, destinationPageIDs: [pageIDs[0]],
      sourcePageIndices: [0, 1])
    let result = try command.preflight(in: destination)
    let resultPages = try PDFPageTree.pageIDs(in: result.graph)
    #expect(resultPages.count == 2)
    let allText = try pageTexts(result.graph).joined()
    #expect(allText.contains("SRC-1"))
    #expect(allText.contains("SRC-2"))
    #expect(throws: Never.self) { try result.graph.validate(limits: PDFLimits()) }
  }
}
