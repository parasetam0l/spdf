import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// PAG-07: batch sequence continuity, prefix/suffix, digit width, placement,
/// exclusions, verification and the filename/mapping report.
@Suite("Bates batch numbering")
struct BatesBatchTests {
  private func settings(
    prefix: String = "ABC-", suffix: String = "", startNumber: Int = 1,
    digits: Int = 5, continues: Bool = true, excludedPages: [Int] = [],
    leadingExcludedPages: Int = 0
  ) -> BatesBatchSettings {
    BatesBatchSettings(
      prefix: prefix, suffix: suffix, startNumber: startNumber, digits: digits,
      style: AddedTextStyle(size: 8), placement: .bottomCenter, margin: 30,
      continuesAcrossFiles: continues, excludedPages: excludedPages,
      leadingExcludedPages: leadingExcludedPages)
  }

  @Test func reorderedFilesProduceTheRequestedUniqueContinuousSequence() throws {
    let a = BatesBatchFile(name: "alpha.pdf", pageCount: 3)
    let b = BatesBatchFile(name: "beta.pdf", pageCount: 2)
    let plan = try BatesBatchPlanner.plan(
      files: [a, b], settings: settings(startNumber: 100, digits: 5))
    #expect(plan.files.map(\.name) == ["alpha.pdf", "beta.pdf"])
    #expect(plan.files[0].pages.map(\.number) == [100, 101, 102])
    #expect(plan.files[1].pages.map(\.number) == [103, 104])
    #expect(plan.files[0].pages.map(\.text) == ["ABC-00100", "ABC-00101", "ABC-00102"])
    #expect(plan.files[1].pages.last?.text == "ABC-00104")
    let numbers = plan.files.flatMap { $0.pages.map(\.number) }
    #expect(numbers.count == Set(numbers).count)
    #expect(plan.sequenceStart == 100)
    #expect(plan.sequenceEnd == 104)
    #expect(plan.numberedPages == 5)
    #expect(plan.files[0].firstPage == 1)
    #expect(plan.files[0].lastPage == 3)

    // Reordering the same inputs produces the requested assignment for the
    // new order instead of reusing the old one.
    let reordered = try BatesBatchPlanner.plan(
      files: [b, a], settings: settings(startNumber: 100, digits: 5))
    #expect(reordered.files.map(\.name) == ["beta.pdf", "alpha.pdf"])
    #expect(reordered.files[0].pages.map(\.number) == [100, 101])
    #expect(reordered.files[1].pages.map(\.number) == [102, 103, 104])
    let reorderedNumbers = reordered.files.flatMap { $0.pages.map(\.number) }
    #expect(reorderedNumbers.count == Set(reorderedNumbers).count)
  }

  @Test func prefixSuffixAndDigitWidthAreAppliedToEveryPage() throws {
    let plan = try BatesBatchPlanner.plan(
      files: [BatesBatchFile(name: "doc.pdf", pageCount: 3)],
      settings: settings(prefix: "CASE/", suffix: "/CONF", startNumber: 7, digits: 4))
    #expect(plan.files[0].pages.map(\.text) == [
      "CASE/0007/CONF", "CASE/0008/CONF", "CASE/0009/CONF",
    ])
    #expect(plan.settings.formatDescription.contains("CASE/0007/CONF"))
  }

  @Test func exclusionsSkipPagesWithoutConsumingNumbers() throws {
    let plan = try BatesBatchPlanner.plan(
      files: [
        BatesBatchFile(name: "front.pdf", pageCount: 4),
        BatesBatchFile(name: "body.pdf", pageCount: 3, excludedPages: [2]),
      ],
      settings: settings(
        prefix: "B-", startNumber: 1, digits: 4, excludedPages: [2],
        leadingExcludedPages: 1))
    #expect(plan.files[0].excludedPages == [1, 2])
    #expect(plan.files[0].pages.map(\.pageIndex) == [3, 4])
    #expect(plan.files[0].pages.map(\.number) == [1, 2])
    // The uniform exclusion plus this file's own excluded page.
    #expect(plan.files[1].excludedPages == [1, 2])
    #expect(plan.files[1].pages.map(\.pageIndex) == [3])
    #expect(plan.files[1].pages.map(\.number) == [3])
    #expect(plan.numberedPages == 3)
    #expect(plan.files[1].pages[0].text == "B-0003")

    // Per-file exclusions can empty a file without breaking the sequence.
    let empty = try BatesBatchPlanner.plan(
      files: [
        BatesBatchFile(name: "skip.pdf", pageCount: 2, excludedPages: [1, 2]),
        BatesBatchFile(name: "keep.pdf", pageCount: 2),
      ],
      settings: settings(digits: 3))
    #expect(empty.files[0].pages.isEmpty)
    #expect(empty.files[0].mark == nil)
    #expect(empty.files[1].pages.map(\.number) == [1, 2])
    #expect(empty.issues.contains { $0.contains("every page is excluded") })
  }

  @Test func restartPerFileResetsTheSequenceForEachFile() throws {
    let plan = try BatesBatchPlanner.plan(
      files: [
        BatesBatchFile(name: "a.pdf", pageCount: 2),
        BatesBatchFile(name: "b.pdf", pageCount: 2),
      ],
      settings: settings(startNumber: 10, digits: 3, continues: false))
    #expect(plan.files[0].pages.map(\.number) == [10, 11])
    #expect(plan.files[1].pages.map(\.number) == [10, 11])
    #expect(plan.sequenceStart == 10)
    #expect(plan.sequenceEnd == 11)
    // Both files use the same numbers, which is the requested restart mode.
    let numbers = plan.files.flatMap { $0.pages.map(\.number) }
    #expect(numbers.count != Set(numbers).count)
  }

  @Test func widerNumbersAreKeptAndDisclosed() throws {
    let plan = try BatesBatchPlanner.plan(
      files: [BatesBatchFile(name: "wide.pdf", pageCount: 3)],
      settings: settings(prefix: "P", startNumber: 9_998, digits: 4))
    #expect(plan.files[0].pages.map(\.number) == [9_998, 9_999, 10_000])
    #expect(plan.files[0].pages.map(\.text) == ["P9998", "P9999", "P10000"])
    #expect(plan.issues.contains { $0.contains("wider than the requested") })
  }

  @Test func invalidRequestsRefuseBeforeAnyMutation() throws {
    #expect(throws: PDFError.self) {
      _ = try BatesBatchPlanner.plan(files: [], settings: settings())
    }
    #expect(throws: PDFError.self) {
      _ = try BatesBatchPlanner.plan(
        files: [BatesBatchFile(name: "a.pdf", pageCount: 1)],
        settings: settings(digits: 0))
    }
    #expect(throws: PDFError.self) {
      _ = try BatesBatchPlanner.plan(
        files: [BatesBatchFile(name: "a.pdf", pageCount: 1)],
        settings: settings(digits: 13))
    }
    #expect(throws: PDFError.self) {
      _ = try BatesBatchPlanner.plan(
        files: [BatesBatchFile(name: "a.pdf", pageCount: 0)], settings: settings())
    }
    #expect(throws: PDFError.self) {
      _ = try BatesBatchPlanner.plan(
        files: [BatesBatchFile(name: "a.pdf", pageCount: 2)],
        settings: settings(excludedPages: [0]))
    }
  }

  @Test func assignmentCommandPaintsPlannedNumbersAndSurvivesReopen() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let plan = try BatesBatchPlanner.plan(
      files: [BatesBatchFile(name: "fixture.pdf", pageCount: parsed.pageCount)],
      settings: settings(prefix: "ABC-", startNumber: 7, digits: 4))
    let assignment = plan.files[0]
    let command = try #require(
      assignment.command(pageIDs: parsed.pageIDs, groupID: "batch-group"))
    let marked = try PDFEditingEngine.commit(PDFTransaction([command]), to: parsed.graph)
    let verification = BatesBatchVerifier.verify(
      graph: marked, pageIDs: parsed.pageIDs, assignment: assignment,
      groupID: "batch-group")
    #expect(verification.isVerified)
    #expect(verification.matchedPages == [1, 2, 3])
    #expect(verification.missingPages.isEmpty)

    let layout = try PageTextLayout.build(pageID: parsed.pageIDs[1], in: marked)
    let text = layout.lines.map { layout.text(in: $0) }.joined(separator: "\n")
    #expect(text.contains("ABC-0008"))

    // The planned numbers and the mark's settings survive Save and reopen.
    let reopened = try PDFParser.parse(PDFWriter.write(marked))
    let reopenedVerification = BatesBatchVerifier.verify(
      graph: reopened.graph, pageIDs: reopened.pageIDs, assignment: assignment,
      groupID: "batch-group")
    #expect(reopenedVerification.isVerified)
    let group = try #require(
      RepeatedMarkInventory.groups(in: reopened.graph, pageIDs: reopened.pageIDs)
        .first { $0.groupID == "batch-group" })
    #expect(group.spec?.kind == .bates)
    #expect(group.spec?.start == 7)
    #expect(group.spec?.digits == 4)
    #expect(group.pageIDs == reopened.pageIDs)
  }

  @Test func verifierDetectsMissingAndUnplannedMarks() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let plan = try BatesBatchPlanner.plan(
      files: [BatesBatchFile(name: "fixture.pdf", pageCount: parsed.pageCount)],
      settings: settings(prefix: "V-", startNumber: 1, digits: 3, excludedPages: [2]))
    let assignment = plan.files[0]
    let command = try #require(
      assignment.command(pageIDs: parsed.pageIDs, groupID: "batch-group"))
    let marked = try PDFEditingEngine.commit(PDFTransaction([command]), to: parsed.graph)

    // Remove the planned mark from the last page.
    let missing = try PDFEditingEngine.commit(
      PDFTransaction([
        RemoveRepeatedMarkCommand(groupID: "batch-group", pageIDs: [parsed.pageIDs[2]])
      ]), to: marked)
    let missingVerification = BatesBatchVerifier.verify(
      graph: missing, pageIDs: parsed.pageIDs, assignment: assignment,
      groupID: "batch-group")
    #expect(!missingVerification.isVerified)
    #expect(missingVerification.missingPages == [3])

    // Paint the set on an excluded page: the verification reports it.
    let extra = try PDFEditingEngine.commit(
      PDFTransaction([
        AddRepeatedMarkCommand(
          pageIDs: [parsed.pageIDs[1]],
          mark: .bates(
            prefix: "V-", suffix: "", start: 99, digits: 3,
            style: AddedTextStyle(size: 8)),
          groupID: "batch-group")
      ]), to: marked)
    let extraVerification = BatesBatchVerifier.verify(
      graph: extra, pageIDs: parsed.pageIDs, assignment: assignment,
      groupID: "batch-group")
    #expect(!extraVerification.isVerified)
    #expect(extraVerification.unexpectedPages == [2])
  }

  @Test func mappingReportCarriesFilenamesSequenceAndVerification() throws {
    let files = [
      BatesBatchFile(name: "alpha.pdf", pageCount: 3),
      BatesBatchFile(name: "beta.pdf", pageCount: 2),
    ]
    let plan = try BatesBatchPlanner.plan(
      files: files,
      settings: settings(prefix: "CASE-", suffix: "-X", startNumber: 10, digits: 5))
    let report = BatesMappingReport(plan: plan, verifications: [])
    #expect(!report.isVerified)
    let csv = report.csv()
    #expect(csv.contains("Order,File,Pages,NumberedPages"))
    #expect(csv.contains("alpha.pdf"))
    #expect(csv.contains("beta.pdf"))
    #expect(csv.contains("CASE-"))
    #expect(csv.contains("-X"))
    #expect(csv.contains("continuous"))
    #expect(csv.split(separator: "\n").count >= 3)

    let json = try JSONSerialization.jsonObject(with: try report.jsonData())
    let object = try #require(json as? [String: Any])
    let rows = try #require(object["files"] as? [[String: Any]])
    #expect(rows.count == 2)
    #expect(rows[0]["file"] as? String == "alpha.pdf")
    #expect(rows[1]["file"] as? String == "beta.pdf")
    #expect(rows[0]["firstBatesNumber"] as? Int == 10)
    #expect(rows[1]["lastBatesNumber"] as? Int == 14)
    let assignments = try #require(rows[0]["pageAssignments"] as? [[String: Any]])
    #expect(assignments.count == 3)
    #expect(assignments[1]["text"] as? String == "CASE-00011-X")
    let settingsObject = try #require(object["settings"] as? [String: Any])
    #expect(settingsObject["prefix"] as? String == "CASE-")
    #expect(settingsObject["digits"] as? Int == 5)
    #expect(object["sequenceStart"] as? Int == 10)
    #expect(object["sequenceEnd"] as? Int == 14)
  }

  @Test func verifiedReportCountsEveryFile() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let plan = try BatesBatchPlanner.plan(
      files: [BatesBatchFile(name: "one.pdf", pageCount: 1)],
      settings: settings(startNumber: 1, digits: 3))
    let assignment = plan.files[0]
    let command = try #require(
      assignment.command(pageIDs: parsed.pageIDs, groupID: "one-group"))
    let marked = try PDFEditingEngine.commit(PDFTransaction([command]), to: parsed.graph)
    let verification = BatesBatchVerifier.verify(
      graph: marked, pageIDs: parsed.pageIDs, assignment: assignment,
      groupID: "one-group")
    let report = BatesMappingReport(plan: plan, verifications: [verification])
    #expect(report.isVerified)
    #expect(report.summary.contains("1 verified"))
    #expect(report.summary.contains("one.pdf"))
  }

  @Test func pageListFormattingCompressesRanges() {
    #expect(BatesBatchPlanner.formatPageList([1, 2, 3, 5, 7, 8]) == "1-3, 5, 7-8")
    #expect(BatesBatchPlanner.formatPageList([]) == "")
    #expect(BatesBatchPlanner.formatPageList([4]) == "4")
  }
}
