import Foundation
import PDFCore
import PDFFixtures
@testable import PDFEditing
import Testing

/// P23-003/P23-006–P23-019/P23-022/P23-024/P23-026–P23-029: page duplication,
/// crop editing, range parsing, extraction/splitting, merging with remapping,
/// repair, destination handling, and field-name collisions.
@Suite("Document assembly")
struct DocumentAssemblyTests {
  private func graph() throws -> PDFGraph {
    try PDFParser.parse(PDFFixtures.threePages()).graph
  }

  // MARK: - P23-024

  @Test func rangeParsingHandlesReversedAndOpenRanges() {
    #expect(PageRange.parse("1-3,5", pageCount: 10) == [0, 1, 2, 4])
    #expect(PageRange.parse("3-1", pageCount: 10) == [0, 1, 2])
    #expect(PageRange.parse("2-", pageCount: 4) == [1, 2, 3])
    #expect(PageRange.parse("-2", pageCount: 4) == [0, 1])
    #expect(PageRange.parse("9", pageCount: 3) == [2])
    #expect(PageRange.parse("1,1,2", pageCount: 5) == [0, 1])
    #expect(PageRange.parse("0,-,x", pageCount: 5) == [])
  }

  // MARK: - P23-003/P23-026

  @Test func duplicationSharesResourcesAndRepairsCounts() throws {
    let graph = try graph()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let duplicated = try DocumentAssembly.duplicatePage(pageIDs[1], in: graph)
    let newPageIDs = try PDFPageTree.pageIDs(in: duplicated.graph)
    #expect(newPageIDs.count == 4)
    #expect(newPageIDs[2] == duplicated.newPageID)
    // The copy shares the original's resource references (controlled sharing).
    guard case .dictionary(let original)? = graph.objects[pageIDs[1]],
      case .dictionary(let copy)? = duplicated.graph.objects[duplicated.newPageID]
    else {
      Issue.record("pages missing")
      return
    }
    #expect(copy[PDFName("Resources")] == original[PDFName("Resources")])
    #expect(copy[PDFName("Contents")] == original[PDFName("Contents")])
    // The page-tree count was repaired.
    if case .reference(let catalogID)? = duplicated.graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = duplicated.graph.objects[catalogID],
      case .reference(let pagesID)? = catalog[PDFName("Pages")],
      case .dictionary(let pages)? = duplicated.graph.objects[pagesID],
      case .integer(let count)? = pages[PDFName("Count")]
    {
      #expect(count == 4)
    }
    // Independent resources when requested.
    let independent = try DocumentAssembly.duplicatePage(
      pageIDs[1], in: graph, duplicateResources: true)
    if case .dictionary(let copy)? = independent.graph.objects[independent.newPageID],
      case .reference(let resourcesID)? = copy[PDFName("Resources")],
      case .dictionary(let resources)? = independent.graph.objects[resourcesID]
    {
      #expect(!resources.isEmpty)
    } else {
      Issue.record("independent resources missing")
    }
    // P23-026: the source graph is untouched.
    #expect(try PDFPageTree.pageIDs(in: graph).count == 3)
  }

  // MARK: - P23-006/P23-007

  @Test func cropEditingIsNonDestructive() throws {
    let graph = try graph()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let cropped = try DocumentAssembly.setCropBox(
      [20, 20, 500, 700], pageID: pageID, in: graph)
    let attributes = PDFDocumentInventory.pageAttributes(pageIDs: [pageID], in: cropped)
    #expect(attributes[0].cropBox == [20, 20, 500, 700])
    // Content is untouched: this is not redaction.
    guard case .dictionary(let before)? = graph.objects[pageID],
      case .dictionary(let after)? = cropped.objects[pageID]
    else {
      Issue.record("page missing")
      return
    }
    #expect(before[PDFName("Contents")] == after[PDFName("Contents")])
    // Out-of-bounds crop boxes are refused.
    #expect(throws: PDFError.self) {
      try DocumentAssembly.setCropBox([-10, -10, 100, 100], pageID: pageID, in: graph)
    }
  }

  @Test func multiPageCropUsesEachPageMediaBoxAndOneTransaction() throws {
    let graph = try graph()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let boxes = [
      pageIDs[0]: [20.0, 20, 500, 700],
      pageIDs[1]: [10.0, 10, 400, 600],
    ]
    let cropped = try PDFEditingEngine.commit(
      PDFTransaction([DocumentAssembly.SetCropBoxCommand(boxes: boxes)]), to: graph)
    let attributes = PDFDocumentInventory.pageAttributes(
      pageIDs: Array(boxes.keys), in: cropped)
    for attribute in attributes {
      #expect(attribute.cropBox == boxes[attribute.pageObjectID])
    }
    // A box outside its own MediaBox refuses before mutating anything.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          DocumentAssembly.SetCropBoxCommand(boxes: [pageIDs[0]: [-10, -10, 100, 100]])
        ]), to: graph)
    }
  }

  @Test func trimBoxUsesTheSharedPageBoxTransaction() throws {
    let graph = try graph()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let attributes = PDFDocumentInventory.pageAttributes(pageIDs: [pageID], in: graph)
    let media = attributes[0].mediaBox
    let box = [media[0] + 5, media[1] + 5, media[2] - 5, media[3] - 5]
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        DocumentAssembly.SetPageBoxCommand(boxes: [pageID: box], kind: .trim)
      ]), to: graph)
    let changed = PDFDocumentInventory.pageAttributes(pageIDs: [pageID], in: edited)
    #expect(changed[0].trimBox == box)
    // The visible crop box is untouched.
    #expect(changed[0].cropBox == attributes[0].cropBox)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          DocumentAssembly.SetPageBoxCommand(
            boxes: [pageID: [media[0] - 20, media[1], media[2], media[3]]],
            kind: .bleed)
        ]), to: graph)
    }
  }

  // MARK: - P23-008/P23-009/P23-014/P23-015/P23-017

  @Test func extractionKeepsSelectedPagesAndDropsForeignTargets() throws {
    let graph = try graph()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    // A link on page 1 pointing at page 3 (survives) and one pointing at a
    // page we will not extract (dropped).
    var source = graph
    let linkID = DocumentAssembly.nextObjectID(in: source)
    source.objects[linkID] = .dictionary([
      PDFName("Type"): .name(PDFName("Annot")),
      PDFName("Subtype"): .name(PDFName("Link")),
      PDFName("Rect"): .array([
        .integer(10), .integer(10), .integer(60), .integer(30),
      ]),
      PDFName("Dest"): .array([.reference(pageIDs[2]), .name(PDFName("Fit"))]),
    ])
    let droppedLinkID = PDFObjectID(linkID.number + 1)
    source.objects[droppedLinkID] = .dictionary([
      PDFName("Type"): .name(PDFName("Annot")),
      PDFName("Subtype"): .name(PDFName("Link")),
      PDFName("Rect"): .array([
        .integer(10), .integer(40), .integer(60), .integer(60),
      ]),
      PDFName("Dest"): .array([.reference(pageIDs[1]), .name(PDFName("Fit"))]),
    ])
    if case .dictionary(var page)? = source.objects[pageIDs[0]] {
      page[PDFName("Annots")] = .array([.reference(linkID), .reference(droppedLinkID)])
      source.objects[pageIDs[0]] = .dictionary(page)
    }

    // Extract pages 1 and 3.
    let extracted = try DocumentAssembly.extract(
      source, pageIDs: [pageIDs[0], pageIDs[2]])
    let extractedPages = try PDFPageTree.pageIDs(in: extracted.graph)
    #expect(extractedPages.count == 2)
    // The surviving destination points at the extracted page 2.
    let annotations = try AnnotationInventory.annotations(
      in: extracted.graph, pageID: extractedPages[0])
    #expect(annotations.count == 1)
    let destination = try #require({
      if case .array(let values)? = annotations[0].dictionary[PDFName("Dest")] { return values }
      return nil
    }())
    guard case .reference(let target) = destination[0] else {
      Issue.record("destination missing")
      return
    }
    #expect(target == extractedPages[1])
    #expect(extracted.report.droppedDestinations >= 1)
    // The extracted document validates and reparses.
    let data = try PDFWriter.write(extracted.graph)
    let reparsed = try PDFParser.parse(data)
    #expect(try PDFPageTree.pageIDs(in: reparsed.graph).count == 2)
  }

  // MARK: - P23-010/P23-011/P23-012/P23-013/P23-018/P23-022

  @Test func mergeRemapsObjectsRepairsTreesAndRenamesFields() throws {
    let first = try graph()
    let firstPages = try PDFPageTree.pageIDs(in: first)
    // Two widgets with the same field name in both documents.
    func withField(_ graph: PDFGraph, pageID: PDFObjectID, name: String) -> PDFGraph {
      var graph = graph
      let widgetID = DocumentAssembly.nextObjectID(in: graph)
      graph.objects[widgetID] = .dictionary([
        PDFName("Type"): .name(PDFName("Annot")),
        PDFName("Subtype"): .name(PDFName("Widget")),
        PDFName("FT"): .name(PDFName("Tx")),
        PDFName("T"): .string(AnnotationText.encode(name)),
        PDFName("Rect"): .array([
          .integer(10), .integer(10), .integer(100), .integer(30),
        ]),
      ])
      if case .dictionary(var page)? = graph.objects[pageID] {
        page[PDFName("Annots")] = .array([.reference(widgetID)])
        graph.objects[pageID] = .dictionary(page)
      }
      return graph
    }
    let left = withField(first, pageID: firstPages[0], name: "name")
    let right = withField(first, pageID: firstPages[1], name: "name")
    let merged = try DocumentAssembly.merge([
      (graph: left, pageIDs: [firstPages[0]]),
      (graph: right, pageIDs: [firstPages[1]]),
    ])
    let mergedPages = try PDFPageTree.pageIDs(in: merged.graph)
    #expect(mergedPages.count == 2)
    // Counts and parents were repaired.
    if case .reference(let catalogID)? = merged.graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = merged.graph.objects[catalogID],
      case .reference(let pagesID)? = catalog[PDFName("Pages")],
      case .dictionary(let pages)? = merged.graph.objects[pagesID],
      case .integer(let count)? = pages[PDFName("Count")]
    {
      #expect(count == 2)
    }
    for pageID in mergedPages {
      guard case .dictionary(let page)? = merged.graph.objects[pageID],
        case .reference(let parentID)? = page[PDFName("Parent")],
        case .dictionary(let parent)? = merged.graph.objects[parentID]
      else {
        Issue.record("parent links missing")
        return
      }
      #expect(parent[PDFName("Type")] == .name(PDFName("Pages")))
    }
    // The duplicate field name was renamed with a suffix.
    #expect(merged.report.renamedFields.count == 1)
    let names = try mergedPages.map { pageID -> [String] in
      let annotations = try AnnotationInventory.annotations(in: merged.graph, pageID: pageID)
      return annotations.compactMap { annotation in
        if case .string(let data)? = annotation.dictionary[PDFName("T")] {
          return AnnotationText.decode(data)
        }
        return nil
      }
    }.flatMap { $0 }
    #expect(Set(names).count == 2)
    #expect(names.contains("name"))
    // The merged document reparses and validates.
    let reparsed = try PDFParser.parse(try PDFWriter.write(merged.graph))
    try reparsed.graph.validate()
    #expect(merged.report.remappedObjects > 0)
  }

  // MARK: - P23-022/P23-028/P23-029

  @Test func mergeRefusesProtectedInputsAndStaysBounded() throws {
    let signed = try PDFParser.parse(
      try Data(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Signed/signed-one-page.pdf")))
    #expect(throws: PDFError.self) {
      try DocumentAssembly.merge([(graph: signed.graph, pageIDs: signed.pageIDs)])
    }
    let encrypted = try PDFParser.parse(
      try Data(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Encrypted/aes-256-r6.pdf")), password: "abc")
    #expect(throws: PDFError.self) {
      try DocumentAssembly.merge([(graph: encrypted.graph, pageIDs: encrypted.pageIDs)])
    }

    // A larger merge stays within a bounded time.
    let graph = try graph()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let start = ContinuousClock.now
    let merged = try DocumentAssembly.merge(
      (0..<10).map { _ in (graph: graph, pageIDs: pageIDs) })
    let milliseconds = Int((ContinuousClock.now - start).components.seconds * 1000)
    print("[P23-029] 10×3-page merge \(milliseconds) ms")
    #expect(try PDFPageTree.pageIDs(in: merged.graph).count == 30)
    #expect(milliseconds < 10_000)
  }
}

/// P08-027: outline and destination targets survive page-identity mapping
/// (reordering keeps page objects, so targets stay correct).
@Suite("Identity mapping")
struct IdentityMappingTests {
  @Test func destinationsAndOutlinesSurviveReordering() throws {
    var graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    // A named destination and an outline pointing at the last page.
    if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    {
      catalog[PDFName("Dests")] = .dictionary([
        PDFName("last"): .array([.reference(pageIDs[2]), .name(PDFName("Fit"))])
      ])
      catalog[PDFName("Outlines")] = .reference(PDFObjectID(500))
      graph.objects[PDFObjectID(500)] = .dictionary([
        PDFName("Type"): .name(PDFName("Outlines")),
        PDFName("First"): .reference(PDFObjectID(501)),
        PDFName("Last"): .reference(PDFObjectID(501)),
        PDFName("Count"): .integer(1),
      ])
      graph.objects[PDFObjectID(501)] = .dictionary([
        PDFName("Title"): .string(Data("Last page".utf8)),
        PDFName("Parent"): .reference(PDFObjectID(500)),
        PDFName("Dest"): .array([.reference(pageIDs[2]), .name(PDFName("Fit"))]),
      ])
      graph.objects[catalogID] = .dictionary(catalog)
    }
    // Reorder: move the first page to the end; the destination still targets
    // the same page object (now at index 2).
    let reordered = try PDFEditingEngine.commit(
      PDFTransaction([ReorderPagesCommand(pageID: pageIDs[0], toIndex: 2)]), to: graph)
    let newOrder = try PDFPageTree.pageIDs(in: reordered)
    #expect(newOrder.last == pageIDs[0])
    // The destination's page reference is unchanged and still resolves.
    guard case .reference(let catalogID)? = reordered.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = reordered.objects[catalogID],
      case .dictionary(let dests)? = catalog[PDFName("Dests")],
      case .array(let target)? = dests[PDFName("last")],
      case .reference(let targetPage) = target[0]
    else {
      Issue.record("destination missing after reorder")
      return
    }
    #expect(targetPage == pageIDs[2])
    #expect(newOrder.contains(targetPage))
    // The outline item survives with its target intact.
    guard case .dictionary(let outline)? = reordered.objects[PDFObjectID(501)],
      case .array(let outlineDest)? = outline[PDFName("Dest")],
      case .reference(let outlineTarget) = outlineDest[0]
    else {
      Issue.record("outline missing after reorder")
      return
    }
    #expect(outlineTarget == pageIDs[2])
    // Independent reopening sees the same facts.
    let reparsed = try PDFParser.parse(try PDFWriter.write(reordered))
    let items = PDFOutlineInventory.items(in: reparsed.graph, pageIDs: reparsed.pageIDs)
    #expect(!items.isEmpty)
  }
}

/// P23-016: outlines are rebuilt with remapped targets during extraction and
/// merging, and dropped (with a count) when their targets do not survive.
@Suite("Outline rebuilding")
struct OutlineRebuildingTests {
  private func graphWithOutline() throws -> PDFGraph {
    var graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    {
      catalog[PDFName("Outlines")] = .reference(PDFObjectID(500))
      graph.objects[PDFObjectID(500)] = .dictionary([
        PDFName("Type"): .name(PDFName("Outlines")),
        PDFName("First"): .reference(PDFObjectID(501)),
        PDFName("Last"): .reference(PDFObjectID(502)),
        PDFName("Count"): .integer(2),
      ])
      graph.objects[PDFObjectID(501)] = .dictionary([
        PDFName("Title"): .string(Data("First".utf8)),
        PDFName("Parent"): .reference(PDFObjectID(500)),
        PDFName("Dest"): .array([.reference(pageIDs[0]), .name(PDFName("Fit"))]),
        PDFName("Next"): .reference(PDFObjectID(502)),
      ])
      graph.objects[PDFObjectID(502)] = .dictionary([
        PDFName("Title"): .string(Data("Third".utf8)),
        PDFName("Parent"): .reference(PDFObjectID(500)),
        PDFName("Dest"): .array([.reference(pageIDs[2]), .name(PDFName("Fit"))]),
        PDFName("Prev"): .reference(PDFObjectID(501)),
      ])
      graph.objects[catalogID] = .dictionary(catalog)
    }
    return graph
  }

  @Test func extractionRebuildsOutlinesWithRemappedTargets() throws {
    let graph = try graphWithOutline()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let extracted = try DocumentAssembly.extract(
      graph, pageIDs: [pageIDs[0], pageIDs[2]])
    let items = PDFOutlineInventory.items(
      in: extracted.graph, pageIDs: try PDFPageTree.pageIDs(in: extracted.graph))
    #expect(items.count == 2)
    #expect(items[0].title == "First")
    #expect(items[0].pageIndex == 0)
    #expect(items[1].title == "Third")
    #expect(items[1].pageIndex == 1)
    // Dropping a page drops the item and reports it.
    let partial = try DocumentAssembly.extract(graph, pageIDs: [pageIDs[1]])
    let partialItems = PDFOutlineInventory.items(
      in: partial.graph, pageIDs: try PDFPageTree.pageIDs(in: partial.graph))
    #expect(partialItems.isEmpty)
    #expect(partial.report.droppedOutlines == 2)
    // Independent reopening keeps the rebuilt outline.
    let reparsed = try PDFParser.parse(try PDFWriter.write(extracted.graph))
    let reopened = PDFOutlineInventory.items(
      in: reparsed.graph, pageIDs: reparsed.pageIDs)
    #expect(reopened.map(\.title) == ["First", "Third"])
  }

  @Test func mergeRebuildsOutlinesFromAllSources() throws {
    let graph = try graphWithOutline()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let merged = try DocumentAssembly.merge([
      (graph: graph, pageIDs: [pageIDs[0]]),
      (graph: graph, pageIDs: [pageIDs[2]]),
    ])
    let mergedPages = try PDFPageTree.pageIDs(in: merged.graph)
    let items = PDFOutlineInventory.items(in: merged.graph, pageIDs: mergedPages)
    #expect(items.count == 2)
    #expect(items[0].pageIndex == 0)
    #expect(items[1].pageIndex == 1)
    try merged.graph.validate()
  }
}

/// P23-021: catalog/name-tree policy — the first document's embedded files are
/// carried with remapped objects; later documents' catalog data is reported.
@Suite("Catalog data policy")
struct CatalogDataPolicyTests {
  private func graphWithAttachment() throws -> PDFGraph {
    var graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    {
      catalog[PDFName("Names")] = .dictionary([
        PDFName("EmbeddedFiles"): .dictionary([
          PDFName("Names"): .array([
            .string(Data("note.txt".utf8)), .reference(PDFObjectID(700)),
          ])
        ])
      ])
      catalog[PDFName("Metadata")] = .reference(PDFObjectID(702))
      graph.objects[catalogID] = .dictionary(catalog)
      graph.objects[PDFObjectID(700)] = .dictionary([
        PDFName("Type"): .name(PDFName("Filespec")),
        PDFName("F"): .string(Data("note.txt".utf8)),
        PDFName("EF"): .dictionary([PDFName("F"): .reference(PDFObjectID(701))]),
      ])
      graph.objects[PDFObjectID(701)] = .stream(PDFStream(bytes: Data("payload".utf8)))
      graph.objects[PDFObjectID(702)] = .stream(
        PDFStream(bytes: Data("<x:xmpmeta/>".utf8)))
    }
    return graph
  }

  @Test func firstDocumentDataIsCarriedAndOthersReported() throws {
    let graph = try graphWithAttachment()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    // Extraction carries the first document's attachments and metadata.
    let extracted = try DocumentAssembly.extract(graph, pageIDs: [pageIDs[0]])
    let attachments = PDFAttachmentInventory.attachments(in: extracted.graph)
    #expect(attachments.count == 1)
    #expect(attachments.first?.name == "note.txt")
    // The payload bytes are remapped but identical.
    let data = try PDFAttachmentInventory.data(of: try #require(attachments.first), in: extracted.graph)
    #expect(data == Data("payload".utf8))
    // Merging two documents keeps only the first one's catalog data, and says so.
    let merged = try DocumentAssembly.merge([
      (graph: graph, pageIDs: [pageIDs[0]]),
      (graph: graph, pageIDs: [pageIDs[1]]),
    ])
    #expect(merged.report.notes.contains { $0.contains("not carried over") || $0.contains("Carried") })
    let mergedPages = try PDFPageTree.pageIDs(in: merged.graph)
    #expect(PDFAttachmentInventory.attachments(in: merged.graph).count == 1)
    // The merged document reparses with the attachment intact.
    let reparsed = try PDFParser.parse(try PDFWriter.write(merged.graph))
    let reopened = PDFAttachmentInventory.attachments(in: reparsed.graph)
    #expect(reopened.count == 1)
  }
}

/// P23-020: the first document's structure tree is imported with page
/// associations remapped to surviving pages (and pruned for dropped ones).
@Suite("Structure tree import")
struct StructureTreeImportTests {
  private func graphWithStructure() throws -> (graph: PDFGraph, pages: [PDFObjectID]) {
    var graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pages = try PDFPageTree.pageIDs(in: graph)
    if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    {
      catalog[PDFName("StructTreeRoot")] = .reference(PDFObjectID(710))
      graph.objects[catalogID] = .dictionary(catalog)
      graph.objects[PDFObjectID(710)] = .dictionary([
        PDFName("Type"): .name(PDFName("StructTreeRoot")),
        PDFName("K"): .array([.reference(PDFObjectID(711))]),
      ])
      graph.objects[PDFObjectID(711)] = .dictionary([
        PDFName("Type"): .name(PDFName("StructElem")),
        PDFName("S"): .name(PDFName("P")),
        PDFName("P"): .reference(PDFObjectID(710)),
        PDFName("Pg"): .reference(pages[0]),
        PDFName("K"): .integer(0),
      ])
    }
    return (graph, pages)
  }

  @Test func structureTreeIsCarriedWithPageAssociations() throws {
    let (graph, pages) = try graphWithStructure()
    // Extracting the page the element points at remaps /Pg to the new page.
    let extracted = try DocumentAssembly.extract(graph, pageIDs: [pages[0]])
    let newPages = try PDFPageTree.pageIDs(in: extracted.graph)
    guard case .reference(let rootID)? = extracted.graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = extracted.graph.objects[rootID],
      case .reference(let structID)? = catalog[PDFName("StructTreeRoot")],
      case .dictionary(let root)? = extracted.graph.objects[structID],
      case .array(let kids)? = root[PDFName("K")],
      case .reference(let elemID) = kids[0],
      case .dictionary(let element)? = extracted.graph.objects[elemID]
    else {
      Issue.record("structure tree missing after extraction")
      return
    }
    #expect(element[PDFName("Pg")] == .reference(newPages[0]))
    #expect(element[PDFName("S")] == .name(PDFName("P")))
    // The cycle back to the root is preserved on the remapped objects.
    #expect(element[PDFName("P")] == .reference(structID))
    // Extracting a different page prunes the association rather than dangling.
    let other = try DocumentAssembly.extract(graph, pageIDs: [pages[1]])
    if case .reference(let otherRoot)? = other.graph.trailer[PDFName("Root")],
      case .dictionary(let otherCatalog)? = other.graph.objects[otherRoot],
      case .reference(let otherStruct)? = otherCatalog[PDFName("StructTreeRoot")],
      case .dictionary(let otherStructRoot)? = other.graph.objects[otherStruct],
      case .array(let otherKids)? = otherStructRoot[PDFName("K")],
      case .reference(let otherElemID) = otherKids[0],
      case .dictionary(let otherElement)? = other.graph.objects[otherElemID]
    {
      #expect(otherElement[PDFName("Pg")] == .null)
    } else {
      Issue.record("structure tree missing after pruning extraction")
    }
    // Merging carries and reports the first document's structure tree.
    let merged = try DocumentAssembly.merge([
      (graph: graph, pageIDs: [pages[0]]),
      (graph: graph, pageIDs: [pages[2]]),
    ])
    #expect(merged.report.notes.contains { $0.contains("structure tree") })
    // The policy off drops it entirely.
    let none = try DocumentAssembly.extract(graph, pageIDs: [pages[0]], catalogData: .none)
    if case .reference(let noneRoot)? = none.graph.trailer[PDFName("Root")],
      case .dictionary(let noneCatalog)? = none.graph.objects[noneRoot]
    {
      #expect(noneCatalog[PDFName("StructTreeRoot")] == nil)
    } else {
      Issue.record("catalog missing")
    }
  }
}
