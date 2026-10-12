import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P33-022/P33-023/P33-029 evidence: assisted tagging suggestions that stay
/// unconfirmed until reviewed, acceptance that creates real marked content and
/// structure, artifact acceptance that never touches the structure tree, and
/// bounded inspection on a heavily tagged synthetic document.
@Suite("Structure tagging assistant")
struct StructureTaggingTests {
  /// An untagged two-page document: heading, body paragraph, image, and a
  /// footer that repeats on both pages.
  private func untagged() -> (graph: PDFGraph, pageIDs: [PDFObjectID]) {
    let image = Data([0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0])
    let pageOne = """
      BT /F1 20 Tf 42 710 Td (Quarterly Report) Tj ET
      BT /F1 12 Tf 42 640 Td (First body line of the report.) Tj ET
      BT /F1 12 Tf 42 624 Td (Second body line follows here.) Tj ET
      BT /F1 12 Tf 42 608 Td (Third body line ends the block.) Tj ET
      BT /F1 9 Tf 42 40 Td (Confidential - internal use only) Tj ET
      q 100 0 0 100 300 500 cm /Im1 Do Q

      """
    let pageTwo = """
      BT /F1 12 Tf 42 640 Td (Page two body text.) Tj ET
      BT /F1 9 Tf 42 40 Td (Confidential - internal use only) Tj ET

      """
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(2),
          PDFName("Kids"): .array([.reference(PDFObjectID(4)), .reference(PDFObjectID(6))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))]),
            PDFName("XObject"): .dictionary([PDFName("Im1"): .reference(PDFObjectID(8))]),
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(pageOne.utf8))),
        PDFObjectID(6): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(7)),
        ]),
        PDFObjectID(7): .stream(PDFStream(bytes: Data(pageTwo.utf8))),
        PDFObjectID(8): .stream(
          PDFStream(
            dictionary: [
              PDFName("Type"): .name(PDFName("XObject")),
              PDFName("Subtype"): .name(PDFName("Image")),
              PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
              PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
              PDFName("BitsPerComponent"): .integer(8),
            ], bytes: image)),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    return (graph, [PDFObjectID(4), PDFObjectID(6)])
  }

  private func text(of pageID: PDFObjectID, in graph: PDFGraph) throws -> String {
    try PageTextLayout.build(pageID: pageID, in: graph).clusters.map(\.text).joined()
  }

  @Test func suggestionsRequireReviewAndStayUnconfirmed() throws {
    let (graph, pageIDs) = untagged()
    let suggestions = try StructureTaggingAssistant.analyze(pageIDs: pageIDs, in: graph)

    // Heading, paragraph, figure, and one footer artifact per page.
    #expect(suggestions.count == 6)
    #expect(suggestions.contains { if case .heading(let level) = $0.kind { return level == 2 } else { return false } })
    #expect(suggestions.filter { if case .paragraph = $0.kind { return true } else { return false } }.count == 2)
    #expect(suggestions.filter { if case .figure = $0.kind { return true } else { return false } }.count == 1)
    #expect(suggestions.filter { if case .artifact = $0.kind { return true } else { return false } }.count == 2)
    #expect(suggestions.allSatisfy { $0.origin == .visualOrderGuess })
    #expect(suggestions.allSatisfy { $0.confidence > 0 && $0.confidence <= 0.95 })
    #expect(suggestions.allSatisfy { !$0.reason.isEmpty && !$0.snippet.isEmpty })
    #expect(suggestions.first?.pageIndex == 0)

    // P33-023: pending suggestions never appear in the reading order.
    let inventory = try PDFStructureInspector.inspect(in: graph, pageIDs: pageIDs)
    #expect(!inventory.isTagged)
    #expect(inventory.elements.isEmpty)

    // P33-022: review state is explicit.
    var review = TaggingReview(suggestions: suggestions)
    #expect(review.pending.count == 6)
    review.accept(suggestions[0].id)
    review.reject(suggestions[1].id)
    #expect(review.status(of: suggestions[0].id) == .accepted)
    #expect(review.status(of: suggestions[1].id) == .rejected)
    #expect(review.pending.count == 4)
    #expect(review.accepted.map(\.id) == [suggestions[0].id])

    // An unaccepted suggestion has no command effect: the graph is untouched.
    #expect(try PDFStructureInspector.inspect(in: graph, pageIDs: pageIDs).elements.isEmpty)
  }

  @Test func acceptHeadingCreatesMarkedContentAndStructure() throws {
    let (graph, pageIDs) = untagged()
    let pageOne = pageIDs[0]
    let before = try text(of: pageOne, in: graph)
    let suggestions = try StructureTaggingAssistant.analyze(pageIDs: pageIDs, in: graph)
    let heading = try #require(suggestions.first {
      if case .heading = $0.kind { return true } else { return false }
    })
    var review = TaggingReview(suggestions: suggestions)
    review.accept(heading.id)
    let command = try #require(TaggingReview.command(for: heading))
    let edited = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)

    // Marked content wraps the original instructions without rewriting them.
    let content = try PageContent.load(pageID: pageOne, in: edited)
    let stream = String(decoding: content.segments[0].decoded, as: UTF8.self)
    #expect(stream.contains("/H2 <</MCID 0>> BDC"))
    #expect(stream.contains("EMC"))
    #expect(stream.contains("(Quarterly Report) Tj"))
    #expect(try text(of: pageOne, in: edited) == before)

    // ParentTree, element, and catalog entries.
    guard case .dictionary(let page)? = edited.objects[pageOne],
      case .integer(let structParents)? = page[PDFName("StructParents")],
      case .dictionary(let catalog)? = edited.objects[PDFObjectID(1)],
      case .reference(let rootID)? = catalog[PDFName("StructTreeRoot")],
      case .dictionary(let root)? = edited.objects[rootID],
      case .dictionary(let parentTree)? = root[PDFName("ParentTree")],
      case .array(let nums)? = parentTree[PDFName("Nums")]
    else {
      Issue.record("Structure root or ParentTree missing")
      return
    }
    #expect(structParents == 0)
    #expect(nums.count == 2)
    guard case .array(let entries) = nums[1], case .reference(let elementID) = entries[0],
      case .dictionary(let element)? = edited.objects[elementID]
    else {
      Issue.record("ParentTree entry missing")
      return
    }
    #expect(element[PDFName("S")] == PDFValue.name(PDFName("H2")))
    #expect(element[PDFName("K")] == PDFValue.integer(0))
    #expect(element[PDFName("Pg")] == PDFValue.reference(pageOne))

    // Inventory resolves the new element; the reading order now includes it.
    let inventory = try PDFStructureInspector.inspect(in: edited, pageIDs: pageIDs)
    #expect(inventory.isTagged)
    #expect(inventory.elements.count == 1)
    #expect(inventory.elements.first?.role == "H2")
    #expect(inventory.elements.first?.pageIndex == 0)
    #expect(inventory.elements.first?.children.contains(.content(pageIndex: 0, mcid: 0)) == true)
    #expect(inventory.issues.isEmpty)
    #expect(inventory.pageMCIDs[0] == [0])

    // Round-trip through the writer and reparse.
    let reparsed = try PDFParser.parse(try PDFWriter.write(edited))
    let reInventory = try PDFStructureInspector.inspect(in: reparsed.graph, pageIDs: reparsed.pageIDs)
    #expect(reInventory.elements.count == 1)
    #expect(try text(of: pageIDs[0], in: reparsed.graph) == before)
  }

  @Test func acceptFigureNeedsReviewerAltText() throws {
    let (graph, pageIDs) = untagged()
    let suggestions = try StructureTaggingAssistant.analyze(pageIDs: pageIDs, in: graph)
    let figure = try #require(suggestions.first {
      if case .figure = $0.kind { return true } else { return false }
    })
    // Without alternate text the suggestion is not ready to apply.
    #expect(TaggingReview.command(for: figure) == nil)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ApplyTaggingSuggestionCommand(
            pageID: figure.pageID, role: PDFName("Figure"), altText: nil,
            content: .image(name: "Im1"))
        ]), to: graph)
    }

    let command = try #require(TaggingReview.command(for: figure, altText: "A green square"))
    let edited = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
    let inventory = try PDFStructureInspector.inspect(in: edited, pageIDs: pageIDs)
    #expect(inventory.elements.first?.role == "Figure")
    #expect(inventory.elements.first?.alt == "A green square")
    let content = try PageContent.load(pageID: figure.pageID, in: edited)
    let stream = String(decoding: content.segments[0].decoded, as: UTF8.self)
    #expect(stream.contains("/Figure <</MCID 0>> BDC"))
    #expect(stream.contains("/Im1 Do"))
  }

  @Test func acceptArtifactWrapsWithoutStructure() throws {
    let (graph, pageIDs) = untagged()
    let pageTwo = pageIDs[1]
    let before = try text(of: pageTwo, in: graph)
    let suggestions = try StructureTaggingAssistant.analyze(pageIDs: pageIDs, in: graph)
    let artifact = try #require(suggestions.first {
      if case .artifact = $0.kind, $0.pageID == pageTwo { return true } else { return false }
    })
    let command = try #require(TaggingReview.command(for: artifact))
    let edited = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
    let content = try PageContent.load(pageID: pageTwo, in: edited)
    let stream = String(decoding: content.segments[0].decoded, as: UTF8.self)
    #expect(stream.contains("/Artifact <</Type /Pagination>> BDC"))
    #expect(!stream.contains("MCID"))
    // Artifacts never enter the structure tree, and visible text is unchanged.
    let inventory = try PDFStructureInspector.inspect(in: edited, pageIDs: pageIDs)
    #expect(!inventory.isTagged)
    #expect(inventory.elements.isEmpty)
    #expect(try text(of: pageTwo, in: edited) == before)
  }

  @Test func taggedFixtureTextResolvesThroughToUnicode() throws {
    // The tagged fixture's Type 3 font has no usable Differences glyph names;
    // its ToUnicode CMap is the decoding source for layout and structure text.
    let parsed = try PDFParser.parse(PDFFixtures.taggedPages())
    let layout = try PageTextLayout.build(pageID: parsed.pageIDs[0], in: parsed.graph)
    let layoutText = layout.clusters.map(\.text).joined()
    #expect(layoutText.contains("Tagged heading"))
    #expect(layoutText.contains("Tagged paragraph text"))
    let inventory = try PDFStructureInspector.inspect(in: parsed.graph, pageIDs: parsed.pageIDs)
    let heading = try #require(inventory.elements.first { $0.role == "H1" })
    #expect(try PDFStructureText.text(of: heading, pageIDs: parsed.pageIDs, in: parsed.graph) == "Tagged heading")
    let paragraph = try #require(inventory.elements.first { $0.role == "P" })
    #expect(
      try PDFStructureText.text(of: paragraph, pageIDs: parsed.pageIDs, in: parsed.graph)
        == "Tagged paragraph text")
  }

  @Test func suggestionsSkipAlreadyTaggedContent() throws {
    let parsed = try PDFParser.parse(PDFFixtures.taggedPages())
    let suggestions = try StructureTaggingAssistant.analyze(
      pageIDs: parsed.pageIDs, in: parsed.graph)
    #expect(suggestions.isEmpty)
  }

  @Test func acceptedTaggingPassesIndependentChecks() throws {
    let (graph, pageIDs) = untagged()
    let before = try text(of: pageIDs[0], in: graph)
    let suggestions = try StructureTaggingAssistant.analyze(pageIDs: pageIDs, in: graph)
    var review = TaggingReview(suggestions: suggestions)
    review.acceptAllPending()
    let commands = review.accepted.compactMap { TaggingReview.command(for: $0, altText: "A green square") }
    #expect(commands.count == 6)
    let edited = try PDFEditingEngine.commit(PDFTransaction(commands), to: graph)
    let data = try PDFWriter.write(edited)

    // Reparse and verify the reading order resolves every accepted element.
    let reparsed = try PDFParser.parse(data)
    let inventory = try PDFStructureInspector.inspect(in: reparsed.graph, pageIDs: reparsed.pageIDs)
    #expect(inventory.isTagged)
    #expect(inventory.elements.count == 4)
    #expect(inventory.issues.isEmpty)
    #expect(try text(of: pageIDs[0], in: reparsed.graph) == before)

    guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/qpdf") else { return }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-tagging-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/qpdf")
    process.arguments = ["--check", url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, "qpdf: \(output)")
  }

  @Test func inspectionStaysBoundedOnHeavilyTaggedDocuments() throws {
    // P33-029: a synthetic heavily tagged document (40 pages x 40 paragraphs
    // under per-page Sect containers = 1,640 elements) with matching marked
    // content, MCIDs, and ParentTree entries.
    let pageCount = 40
    let perPage = 40
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
        PDFName("StructTreeRoot"): .reference(PDFObjectID(3)),
        PDFName("MarkInfo"): .dictionary([PDFName("Marked"): .boolean(true)]),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(Int64(pageCount)),
        PDFName("Kids"): .array(
          (0..<pageCount).map { .reference(PDFObjectID(100 + $0 * 3)) }),
      ]),
      PDFObjectID(3): .dictionary([
        PDFName("Type"): .name(PDFName("StructTreeRoot")),
        PDFName("ParentTree"): .reference(PDFObjectID(4)),
        PDFName("ParentTreeNextKey"): .integer(Int64(pageCount)),
      ]),
    ]
    var numbers: [PDFValue] = []
    var pageElements: [PDFValue] = []
    var elementID = 10_000
    for pageIndex in 0..<pageCount {
      let pageID = PDFObjectID(100 + pageIndex * 3)
      let contentID = PDFObjectID(101 + pageIndex * 3)
      let fontID = PDFObjectID(102 + pageIndex * 3)
      var content = ""
      var entries: [PDFValue] = []
      for mcid in 0..<perPage {
        let id = PDFObjectID(elementID)
        elementID += 1
        content += "/P <</MCID \(mcid)>> BDC\n"
        content += "BT /F1 12 Tf 42 \(760 - mcid * 18) Td (Line \(mcid)) Tj ET\n"
        content += "EMC\n"
        entries.append(.reference(id))
        objects[id] = .dictionary([
          PDFName("Type"): .name(PDFName("StructElem")),
          PDFName("S"): .name(PDFName("P")),
          PDFName("P"): .reference(pageID),
          PDFName("Pg"): .reference(pageID),
          PDFName("K"): .integer(Int64(mcid)),
        ])
      }
      let sectID = PDFObjectID(elementID)
      elementID += 1
      objects[sectID] = .dictionary([
        PDFName("Type"): .name(PDFName("StructElem")),
        PDFName("S"): .name(PDFName("Sect")),
        PDFName("P"): .reference(PDFObjectID(3)),
        PDFName("Pg"): .reference(pageID),
        PDFName("K"): .array(entries),
      ])
      pageElements.append(.reference(sectID))
      numbers.append(.integer(Int64(pageIndex)))
      numbers.append(.array(entries))
      objects[pageID] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(612), .integer(792),
        ]),
        PDFName("Resources"): .dictionary([
          PDFName("Font"): .dictionary([PDFName("F1"): .reference(fontID)])
        ]),
        PDFName("Contents"): .reference(contentID),
        PDFName("StructParents"): .integer(Int64(pageIndex)),
      ])
      objects[contentID] = .stream(PDFStream(bytes: Data(content.utf8)))
      objects[fontID] = .dictionary([
        PDFName("Type"): .name(PDFName("Font")),
        PDFName("Subtype"): .name(PDFName("Type1")),
        PDFName("BaseFont"): .name(PDFName("Helvetica")),
      ])
    }
    objects[PDFObjectID(4)] = .dictionary([PDFName("Nums"): .array(numbers)])
    if case .dictionary(var root)? = objects[PDFObjectID(3)] {
      root[PDFName("K")] = .array(pageElements)
      objects[PDFObjectID(3)] = .dictionary(root)
    }
    let graph = PDFGraph(
      objects: objects, trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    #expect(pageIDs.count == pageCount)

    let start = ContinuousClock.now
    let inventory = try PDFStructureInspector.inspect(in: graph, pageIDs: pageIDs)
    let duration = ContinuousClock.now - start
    let milliseconds = duration.components.seconds * 1000
      + duration.components.attoseconds / 1_000_000_000_000_000
    print("[P33-029] inspect of \(inventory.elements.count) elements: \(milliseconds) ms")
    #expect(inventory.elements.count == pageCount * (perPage + 1))
    #expect(inventory.issues.isEmpty)
    #expect(inventory.pageMCIDs.count == pageCount)
    #expect(inventory.pageMCIDs.allSatisfy { $0.count == perPage })
    #expect(duration < .seconds(5))
  }
}
