import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// PAG-06: an applied mark set can be updated in place after Save/reopen
/// without stacking a duplicate paint, and verification reports what is
/// actually painted.
@Suite("Page mark update and verification")
struct PageMarkUpdateTests {
  private func parsed() throws -> ParsedPDF {
    try PDFParser.parse(PDFFixtures.threePages())
  }

  private func pageText(_ graph: PDFGraph, pageID: PDFObjectID) throws -> String {
    let layout = try PageTextLayout.build(pageID: pageID, in: graph)
    return layout.lines.map { layout.text(in: $0) }.joined(separator: "\n")
  }

  private func occurrences(_ needle: String, in text: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    return text.components(separatedBy: needle).count - 1
  }

  @Test func appliedMarkSetUpdatesInPlaceWithoutStacking() throws {
    let parsed = try parsed()
    let pages = parsed.pageIDs
    let marked = try PDFEditingEngine.commit(
      PDFTransaction([
        AddRepeatedMarkCommand(
          pageIDs: [pages[0], pages[1]],
          mark: .header(text: "DRAFT-ONE", style: AddedTextStyle(size: 10)),
          groupID: "set-a"),
        AddRepeatedMarkCommand(
          pageIDs: [pages[1]],
          mark: .footer(text: "KEEP-ME", style: AddedTextStyle(size: 8)),
          groupID: "set-b"),
      ]), to: parsed.graph)
    #expect(RepeatedMarkInventory.groups(in: marked, pageIDs: pages).count == 2)

    let update = UpdateRepeatedMarkCommand(
      groupID: "set-a", allPageIDs: pages, pageIDs: [pages[0], pages[2]],
      mark: .header(text: "DRAFT-TWO", style: AddedTextStyle(size: 9)),
      margin: 30, placement: .topRight)
    let updated = try PDFEditingEngine.commit(PDFTransaction([update]), to: marked)

    for pageID in [pages[0], pages[2]] {
      let text = try pageText(updated, pageID: pageID)
      #expect(occurrences("DRAFT-TWO", in: text) == 1)
      #expect(!text.contains("DRAFT-ONE"))
    }
    // The page that left the set no longer carries the mark.
    let secondText = try pageText(updated, pageID: pages[1])
    #expect(!secondText.contains("DRAFT-TWO"))
    #expect(!secondText.contains("DRAFT-ONE"))
    // The unrelated set and the fixture's own text survive.
    #expect(secondText.contains("KEEP-ME"))
    #expect(try pageText(updated, pageID: pages[2]).contains("fixture"))

    let groups = RepeatedMarkInventory.groups(in: updated, pageIDs: pages)
    let setA = try #require(groups.first { $0.groupID == "set-a" })
    #expect(setA.pageIDs == [pages[0], pages[2]])
    #expect(setA.spec?.kind == .header)
    #expect(setA.spec?.text == "DRAFT-TWO")
    #expect(setA.spec?.placement == .topRight)
    #expect(setA.spec?.margin == 30)
    #expect(setA.isEditable)
    #expect(setA.label.contains("DRAFT-TWO"))
    #expect(groups.contains { $0.groupID == "set-b" && $0.pageIDs == [pages[1]] })
  }

  @Test func updatingTwiceDoesNotStackPaintOrLeaveUnreferencedStreams() throws {
    let parsed = try parsed()
    let pages = parsed.pageIDs
    let marked = try PDFEditingEngine.commit(
      PDFTransaction([
        AddRepeatedMarkCommand(
          pageIDs: [pages[0], pages[1]],
          mark: .footer(text: "VERSION-ONE", style: AddedTextStyle(size: 8)),
          groupID: "set-a")
      ]), to: parsed.graph)
    func update(_ text: String) throws -> PDFGraph {
      try PDFEditingEngine.commit(
        PDFTransaction([
          UpdateRepeatedMarkCommand(
            groupID: "set-a", allPageIDs: pages, pageIDs: [pages[0], pages[1]],
            mark: .footer(text: text, style: AddedTextStyle(size: 8)))
        ]), to: marked)
    }
    let first = try update("VERSION-TWO")
    let objectsAfterFirst = first.objects.count
    let second = try update("VERSION-THREE")
    // Replacing the set is idempotent in stream count and does not accumulate
    // unreferenced content streams.
    #expect(second.objects.count == objectsAfterFirst)
    for pageID in [pages[0], pages[1]] {
      let text = try pageText(second, pageID: pageID)
      #expect(occurrences("VERSION-THREE", in: text) == 1)
      #expect(!text.contains("VERSION-TWO"))
      #expect(!text.contains("VERSION-ONE"))
      #expect(RepeatedMarkInventory.streamIDs(
        groupID: "set-a", pageID: pageID, in: second).count == 1)
    }
  }

  @Test func savedMarkSetRoundTripsSettingsAndEditsAfterReopen() throws {
    let parsed = try parsed()
    let pages = parsed.pageIDs
    let style = AddedTextStyle(
      family: .times, bold: true, size: 11, color: [0.2, 0.3, 0.4], opacity: 0.6)
    let mark = RepeatedMark.bates(
      prefix: "CASE-", suffix: "-E", start: 42, digits: 4, style: style)
    let marked = try PDFEditingEngine.commit(
      PDFTransaction([
        AddRepeatedMarkCommand(
          pageIDs: pages, mark: mark, margin: 28, groupID: "bates-set",
          placement: .bottomRight)
      ]), to: parsed.graph)
    let bytes = try PDFWriter.write(marked)
    let reopened = try PDFParser.parse(bytes)
    let groups = RepeatedMarkInventory.groups(
      in: reopened.graph, pageIDs: reopened.pageIDs)
    let group = try #require(groups.first { $0.groupID == "bates-set" })
    let spec = try #require(group.spec)
    #expect(group.isEditable)
    #expect(spec.kind == .bates)
    #expect(spec.text == "CASE-")
    #expect(spec.suffix == "-E")
    #expect(spec.start == 42)
    #expect(spec.digits == 4)
    #expect(spec.margin == 28)
    #expect(spec.placement == .bottomRight)
    #expect(spec.makeMark() == mark)
    #expect(spec.expectedText(pageIndex: 0, pageCount: 3) == "CASE-0042-E")
    #expect(spec.expectedText(pageIndex: 2, pageCount: 3) == "CASE-0044-E")

    // The reopened settings drive an in-place update on the reopened graph.
    let update = UpdateRepeatedMarkCommand(
      groupID: group.groupID, allPageIDs: reopened.pageIDs,
      pageIDs: reopened.pageIDs,
      mark: .bates(
        prefix: "CASE-", suffix: "-F", start: 50, digits: 4,
        style: spec.makeMark().style),
      margin: spec.margin, placement: spec.placement)
    let updated = try PDFEditingEngine.commit(PDFTransaction([update]), to: reopened.graph)
    let updatedText = try pageText(updated, pageID: reopened.pageIDs[0])
    #expect(updatedText.contains("CASE-0050-F"))
    #expect(!updatedText.contains("CASE-0042-E"))
    let verified = RepeatedMarkInventory.groups(
      in: updated, pageIDs: reopened.pageIDs).first { $0.groupID == "bates-set" }
    #expect(verified?.spec?.start == 50)
    #expect(verified?.spec?.suffix == "-F")
  }

  @Test func legacyMarkWithoutSettingsIsRemovableButNotEditable() throws {
    let parsed = try parsed()
    let pages = parsed.pageIDs
    var marked = try PDFEditingEngine.commit(
      PDFTransaction([
        AddRepeatedMarkCommand(
          pageIDs: [pages[0]], mark: .header(text: "LEGACY", style: AddedTextStyle(size: 10)),
          groupID: "legacy-set")
      ]), to: parsed.graph)
    // Simulate a set written before settings were stored.
    for pageID in pages {
      for streamID in RepeatedMarkInventory.streamIDs(
        groupID: "legacy-set", pageID: pageID, in: marked)
      {
        guard case .stream(var stream)? = marked.objects[streamID] else { continue }
        stream.dictionary[RepeatedMarkSpec.streamKey] = nil
        marked.objects[streamID] = .stream(stream)
      }
    }
    let group = try #require(
      RepeatedMarkInventory.groups(in: marked, pageIDs: pages).first)
    #expect(group.groupID == "legacy-set")
    #expect(group.spec == nil)
    #expect(!group.isEditable)
    let verification = RepeatedMarkVerifier.verify(group, in: marked, pageIDs: pages)
    #expect(!verification.isVerified)
    #expect(verification.issues.contains { $0.contains("without editable settings") })
    // It remains removable as one unit.
    let removed = try PDFEditingEngine.commit(
      PDFTransaction([
        RemoveRepeatedMarkCommand(groupID: "legacy-set", pageIDs: [pages[0]])
      ]), to: marked)
    #expect(try !pageText(removed, pageID: pages[0]).contains("LEGACY"))
  }

  @Test func verificationReportsNumbersAndDetectsMissingOrStackedMarks() throws {
    let parsed = try parsed()
    let pages = parsed.pageIDs
    let marked = try PDFEditingEngine.commit(
      PDFTransaction([
        AddRepeatedMarkCommand(
          pageIDs: pages,
          mark: .bates(
            prefix: "ABC-", suffix: "/26", start: 7, digits: 4,
            style: AddedTextStyle(size: 8)),
          groupID: "bates")
      ]), to: parsed.graph)
    let group = try #require(
      RepeatedMarkInventory.groups(in: marked, pageIDs: pages).first)
    let good = RepeatedMarkVerifier.verify(group, in: marked, pageIDs: pages)
    #expect(good.isVerified)
    #expect(good.pages.count == 3)
    #expect(good.firstText == "ABC-0007/26")
    #expect(good.lastText == "ABC-0009/26")
    #expect(good.summary.contains("verified"))
    #expect(good.pages[1].visibleText?.contains("ABC-0008/26") == true)

    // Remove the mark from the middle page; the snapshot group still expects it.
    let missing = try PDFEditingEngine.commit(
      PDFTransaction([
        RemoveRepeatedMarkCommand(groupID: "bates", pageIDs: [pages[1]])
      ]), to: marked)
    let missingVerification = RepeatedMarkVerifier.verify(
      group, in: missing, pageIDs: pages)
    #expect(!missingVerification.isVerified)
    #expect(missingVerification.pages[1].streamCount == 0)
    #expect(missingVerification.pages[1].issues.contains { $0.contains("missing") })

    // Stacking a second stream for the same set on a page is detected.
    var stacked = marked
    for pageID in [pages[0]] {
      guard case .dictionary(var page)? = stacked.objects[pageID] else { continue }
      let references = RepeatedMarkInventory.contentReferences(page[PDFName("Contents")])
      var duplicated: [PDFValue] = []
      let streamIDs = Set(
        RepeatedMarkInventory.streamIDs(groupID: "bates", pageID: pageID, in: stacked))
      for reference in references {
        duplicated.append(reference)
        if case .reference(let id) = reference, streamIDs.contains(id) {
          duplicated.append(reference)
        }
      }
      page[PDFName("Contents")] = .array(duplicated)
      stacked.objects[pageID] = .dictionary(page)
    }
    let stackedVerification = RepeatedMarkVerifier.verify(group, in: stacked, pageIDs: pages)
    #expect(!stackedVerification.isVerified)
    #expect(stackedVerification.pages[0].streamCount == 2)
    #expect(stackedVerification.pages[0].issues.contains { $0.contains("applied 2 times") })
  }

  @Test func placementAnchorsMarksToPageCorners() throws {
    let parsed = try parsed()
    let pages = parsed.pageIDs
    let style = AddedTextStyle(size: 8)
    let mark = RepeatedMark.bates(
      prefix: "POS-", suffix: "", start: 1, digits: 3, style: style)
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddRepeatedMarkCommand(
          pageIDs: [pages[0]], mark: mark, margin: 20, groupID: "top-right",
          placement: .topRight),
        AddRepeatedMarkCommand(
          pageIDs: [pages[1]], mark: mark, margin: 20, groupID: "bottom-left",
          placement: .bottomLeft),
      ]), to: parsed.graph)
    let boxes = PDFDocumentInventory.pageAttributes(
      pageIDs: [pages[0], pages[1]], in: graph).map(\.cropBox)
    func markBounds(_ pageID: PDFObjectID, _ needle: String) throws -> [Double] {
      let layout = try PageTextLayout.build(pageID: pageID, in: graph)
      let line = try #require(layout.lines.first {
        layout.text(in: $0).contains(needle)
      })
      let clusters = layout.clusters[line]
      return [
        clusters.map { $0.bounds[0] }.min() ?? 0,
        clusters.map { $0.bounds[1] }.min() ?? 0,
        clusters.map { $0.bounds[2] }.max() ?? 0,
        clusters.map { $0.bounds[3] }.max() ?? 0,
      ]
    }
    let topRight = try markBounds(pages[0], "POS-001")
    let topBox = boxes[0]
    #expect(topRight[2] > topBox[2] - 60)
    #expect(topRight[1] > topBox[3] - 60)
    let bottomLeft = try markBounds(pages[1], "POS-001")
    let bottomBox = boxes[1]
    #expect(bottomLeft[0] < bottomBox[0] + 60)
    #expect(bottomLeft[3] < bottomBox[1] + 60)
  }

  @Test func updatingKindAndPagesKeepsOneSetIdentity() throws {
    let parsed = try parsed()
    let pages = parsed.pageIDs
    let marked = try PDFEditingEngine.commit(
      PDFTransaction([
        AddRepeatedMarkCommand(
          pageIDs: [pages[0]],
          mark: .watermark(text: "DRAFT", style: AddedTextStyle(size: 40), angle: 30),
          groupID: "set")
      ]), to: parsed.graph)
    let update = UpdateRepeatedMarkCommand(
      groupID: "set", allPageIDs: pages, pageIDs: [pages[1], pages[2]],
      mark: .pageNumber(
        text: "Page {page} of {pages}", style: AddedTextStyle(size: 9), offset: 0),
      placement: .bottomCenter)
    let updated = try PDFEditingEngine.commit(PDFTransaction([update]), to: marked)
    #expect(try !pageText(updated, pageID: pages[0]).contains("DRAFT"))
    // A page-number mark numbers its selected pages, matching the add path.
    #expect(try pageText(updated, pageID: pages[1]).contains("Page 1 of 2"))
    #expect(try pageText(updated, pageID: pages[2]).contains("Page 2 of 2"))
    let groups = RepeatedMarkInventory.groups(in: updated, pageIDs: pages)
    #expect(groups.count == 1)
    #expect(groups[0].spec?.kind == .pageNumber)
    #expect(groups[0].pageIDs == [pages[1], pages[2]])
  }

  @Test func updateRefusesWhenTheSetIsGone() throws {
    let parsed = try parsed()
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          UpdateRepeatedMarkCommand(
            groupID: "missing", allPageIDs: parsed.pageIDs, pageIDs: parsed.pageIDs,
            mark: .header(text: "X", style: AddedTextStyle(size: 10)))
        ]), to: parsed.graph)
    }
  }
}
