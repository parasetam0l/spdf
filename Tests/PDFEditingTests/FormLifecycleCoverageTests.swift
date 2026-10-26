import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// FRM-08 evidence: lifecycle coverage for combinations the basic fill/reopen
/// evidence does not exercise (page duplication/deletion with fields, appearance
/// agreement, tab-order stability, and signing combinations incl. post-sign
/// invalidation and sign-after-flatten).
@Suite("Form lifecycle coverage")
struct FormLifecycleCoverageTests {
  private func authoredForm(pages: Int = 2) throws
    -> (graph: PDFGraph, pageIDs: [PDFObjectID])
  {
    let graph = PDFFixtures.graph(pages: pages)
    let pageIDs = try PageTreeView(graph: graph).pages
    let first = pageIDs[0]
    var commands: [any PDFEditCommand] = [
      AddTextFieldCommand(pageID: first, rect: [72, 600, 272, 624], name: "Name"),
      AddChoiceFieldCommand(
        pageID: first, rect: [72, 560, 272, 584], name: "Plan",
        options: [
          AuthoredChoiceOption(exportValue: "Basic"),
          AuthoredChoiceOption(exportValue: "Pro"),
        ]),
      AddCheckboxCommand(pageID: first, rect: [72, 520, 90, 538], name: "Agree"),
      AddSignatureFieldCommand(pageID: first, rect: [72, 480, 272, 504], name: "Signature1"),
    ]
    if pages > 1 {
      commands.append(
        AddTextFieldCommand(
          pageID: pageIDs[1], rect: [72, 600, 272, 624], name: "SecondPageNotes"))
    }
    let edited = try PDFEditingEngine.commit(PDFTransaction(commands), to: graph)
    return (edited, pageIDs)
  }

  private func makeSigner() throws -> (FormLifecycleSigner, TestSigningMaterial) {
    let material = try #require(try TestSigningMaterial.make())
    let signingTime = Date(timeIntervalSince1970: 1_767_225_600)
    let signer: FormLifecycleSigner = { graph in
      let pageIDs = try PageTreeView(graph: graph).pages
      let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
      if fields.contains(where: { $0.kind == .signature && $0.name == "Signature1" }) {
        return try PDFSigningWriter.sign(
          graph, identity: material.identity,
          options: PDFSigningOptions(
            signingTime: signingTime, existingFieldName: "Signature1"))
      }
      return try PDFSigningWriter.sign(
        graph, identity: material.identity,
        options: PDFSigningOptions(
          fieldName: "Signature1", pageIndex: 0, rect: [72, 72, 272, 112],
          signingTime: signingTime))
    }
    return (signer, material)
  }

  @Test func coveragePassesAllExercisedCombinationsWithSigning() throws {
    let (graph, pageIDs) = try authoredForm()
    let (signer, material) = try makeSigner()
    defer { material.cleanUp() }
    let report = try FormLifecycleCoverage.run(
      in: graph, pageIDs: pageIDs, options: .init(signer: signer))
    #expect(
      report.passed,
      "\(report.failed.map { $0.combination + ": " + $0.notes.joined(separator: ", ") }.joined(separator: " | "))")
    #expect(report.failed.isEmpty)
    let combinations = Set(report.exercised.map(\.combination))
    #expect(combinations.contains("fill-appearance-agreement"))
    #expect(combinations.contains("tab-order-agreement"))
    #expect(combinations.contains("duplicate-page-with-fields"))
    #expect(combinations.contains("delete-page-with-fields"))
    #expect(combinations.contains("sign-after-fill"))
    #expect(combinations.contains("signed-document-edit-invalidation"))
    #expect(combinations.contains("export-after-sign"))
    #expect(combinations.contains("sign-after-flatten"))
    #expect(report.findings.allSatisfy { $0.verdict != .notExercised })
    #expect(report.valuesAfterFill["Name"] == "text:Coverage value")
    #expect(report.valuesAfterFill["Plan"] == "choice:Basic")
    #expect(report.valuesAfterFill["Agree"] == "button:Yes")
    #expect(report.tabOrder.contains("SecondPageNotes"))
    #expect(!report.signatureNotes.isEmpty)
    #expect(report.summary.contains("passed"))
  }

  @Test func coverageWithoutSignerMarksOnlySigningCombinationsNotExercised() throws {
    let (graph, pageIDs) = try authoredForm()
    let report = try FormLifecycleCoverage.run(in: graph, pageIDs: pageIDs)
    #expect(report.passed)
    let notExercised = Set(
      report.findings.filter { $0.verdict == .notExercised }.map(\.combination))
    #expect(
      notExercised == [
        "sign-after-fill", "signed-document-edit-invalidation", "export-after-sign",
        "sign-after-flatten",
      ])
    #expect(report.exercised.contains { $0.combination == "duplicate-page-with-fields" })
  }

  @Test func pageDuplicationAndDeletionKeepCanonicalValuesAndTabOrder() throws {
    let (graph, pageIDs) = try authoredForm()
    let report = try FormLifecycleCoverage.run(in: graph, pageIDs: pageIDs)
    let duplicate = try #require(
      report.findings.first { $0.combination == "duplicate-page-with-fields" })
    #expect(duplicate.verdict == .passed)
    #expect(duplicate.notes.joined().contains("page(s)"))
    let deletion = try #require(
      report.findings.first { $0.combination == "delete-page-with-fields" })
    #expect(deletion.verdict == .passed)
    let deletionNotes = deletion.notes.joined()
    #expect(deletionNotes.contains("after deletion") || deletionNotes.contains("refused safely"))
    let tab = try #require(report.findings.first { $0.combination == "tab-order-agreement" })
    #expect(tab.verdict == .passed)
    #expect(tab.notes.joined().contains("rotation keeps the stored tab order"))
    #expect(tab.notes.joined().contains("stored order survives"))
  }

  @Test func signedEditsInvalidateAndSignedExportAgrees() throws {
    let (graph, pageIDs) = try authoredForm()
    let (signer, material) = try makeSigner()
    defer { material.cleanUp() }
    let report = try FormLifecycleCoverage.run(
      in: graph, pageIDs: pageIDs, options: .init(signer: signer))
    let invalidation = try #require(
      report.findings.first { $0.combination == "signed-document-edit-invalidation" })
    #expect(invalidation.verdict == .passed)
    #expect(invalidation.notes.joined().contains("invalidates its signature"))
    let export = try #require(
      report.findings.first { $0.combination == "export-after-sign" })
    #expect(export.verdict == .passed)
    let sign = try #require(report.findings.first { $0.combination == "sign-after-fill" })
    #expect(sign.verdict == .passed)
    #expect(sign.notes.joined().contains("survive signing"))
    #expect(report.signatureNotes.contains { $0.contains("signed document crypto") })
  }

  @Test func signAfterFlattenLeavesOnlyTheSignatureField() throws {
    let (graph, pageIDs) = try authoredForm()
    let (signer, material) = try makeSigner()
    defer { material.cleanUp() }
    let report = try FormLifecycleCoverage.run(
      in: graph, pageIDs: pageIDs, options: .init(signer: signer))
    let flatten = try #require(
      report.findings.first { $0.combination == "sign-after-flatten" })
    #expect(flatten.verdict == .passed)
    #expect(flatten.notes.joined().contains("flat page"))
  }

  @Test func coverageNeverMutatesTheCallerGraph() throws {
    let (graph, pageIDs) = try authoredForm()
    let before = graph
    let pagesBefore = pageIDs
    _ = try FormLifecycleCoverage.run(in: graph, pageIDs: pageIDs)
    #expect(graph == before)
    #expect(pageIDs == pagesBefore)
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    #expect(fields.first { $0.name == "Name" }?.stringValue == nil)
  }

  @Test func coverageRefusesDocumentsWithoutFields() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    #expect(throws: PDFError.self) {
      _ = try FormLifecycleCoverage.run(in: parsed.graph, pageIDs: parsed.pageIDs)
    }
  }
}

