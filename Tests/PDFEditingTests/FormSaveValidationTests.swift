import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// FRM-08 evidence: visible save-time validation findings for field values,
/// declared rules, imported actions, appearances, rich mirrors and signatures.
@Suite("Form save validation")
struct FormSaveValidationTests {
  private func page() throws -> (graph: PDFGraph, pageID: PDFObjectID) {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    return (parsed.graph, parsed.pageIDs[0])
  }

  private func fieldID(_ name: String, in graph: PDFGraph) -> PDFObjectID? {
    FormAuthoringSupport.findField(named: name, in: graph)
  }

  @Test func cleanAuthoredFormHasNoSaveFindings() throws {
    var (graph, pageID) = try page()
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 600, 272, 624], name: "Name"),
        AddCheckboxCommand(pageID: pageID, rect: [72, 560, 90, 578], name: "Agree"),
        SetFormTextCommand(fieldName: "Name", text: "Asha"),
      ]), to: graph)
    let report = FormSaveValidation.validate(in: graph, pageIDs: [pageID])
    #expect(report.isClean, "\(report.findings.map(\.message).joined(separator: "; "))")
    #expect(report.summary.contains("no save-time issues"))
    #expect(!report.hasBlockingErrors)
    #expect(report.saveDisclosure.contains("clean"))
  }

  @Test func requiredEmptyAndMaxLenViolationsAreBlockingErrors() throws {
    var (graph, pageID) = try page()
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(
          pageID: pageID, rect: [72, 600, 272, 624], name: "Name", required: true),
        AddTextFieldCommand(pageID: pageID, rect: [72, 560, 272, 584], name: "Code"),
        SetFormTextCommand(fieldName: "Code", text: "abcdef"),
        SetFormFieldValidationCommand(fieldName: "Code", maxLength: 3),
      ]), to: graph)
    let report = FormSaveValidation.validate(in: graph, pageIDs: [pageID])
    #expect(report.hasBlockingErrors)
    #expect(report.findings.contains {
      $0.code == .requiredFieldEmpty && $0.fieldName == "Name" && $0.severity == .error
    })
    #expect(report.findings.contains {
      $0.code == .valueExceedsMaxLength && $0.fieldName == "Code" && $0.severity == .error
    })
    #expect(report.saveDisclosure.contains("error"))
  }

  @Test func declaredFormatAndCombProblemsAreVisible() throws {
    var (graph, pageID) = try page()
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 600, 272, 624], name: "Amount"),
        SetFormTextCommand(fieldName: "Amount", text: "not a number"),
        SetFormFieldFormatCommand(
          fieldName: "Amount", format: .number(decimals: 2, prefix: nil, suffix: nil)),
        AddTextFieldCommand(pageID: pageID, rect: [72, 560, 272, 584], name: "Comb"),
      ]), to: graph)
    let combID = try #require(fieldID("Comb", in: graph))
    guard case .dictionary(var comb)? = graph.objects[combID] else {
      Issue.record("Comb field missing")
      return
    }
    comb[PDFName("Ff")] = .integer(16_777_216)
    graph.objects[combID] = .dictionary(comb)
    let report = FormSaveValidation.validate(in: graph, pageIDs: [pageID])
    #expect(report.findings.contains {
      $0.code == .valueViolatesFormat && $0.fieldName == "Amount" && $0.severity == .warning
    })
    #expect(report.findings.contains {
      $0.code == .combMissingMaxLength && $0.fieldName == "Comb"
    })
  }

  @Test func importedActionsAreDisclosedButNeverExecuted() throws {
    var (graph, pageID) = try page()
    graph = try PDFEditingEngine.commit(
      PDFTransaction([AddTextFieldCommand(pageID: pageID, rect: [72, 600, 272, 624], name: "Name")]),
      to: graph)
    let nameID = try #require(fieldID("Name", in: graph))
    guard case .dictionary(var field)? = graph.objects[nameID] else {
      Issue.record("field missing")
      return
    }
    field[PDFName("AA")] = .dictionary([
      PDFName("K"): .dictionary([
        PDFName("S"): .name(PDFName("JavaScript")),
        PDFName("JS"): .string(Data("app.alert('x');".utf8)),
      ])
    ])
    graph.objects[nameID] = .dictionary(field)
    let report = FormSaveValidation.validate(in: graph, pageIDs: [pageID])
    let finding = try #require(report.findings.first { $0.code == .importedActionPresent })
    #expect(finding.severity == .warning)
    #expect(finding.fieldName == "Name")
    #expect(finding.disclosure.contains("never executes"))
  }

  @Test func missingAppearanceIsReportedWhenNeedAppearancesIsFalse() throws {
    var (graph, pageID) = try page()
    graph = try PDFEditingEngine.commit(
      PDFTransaction([AddTextFieldCommand(pageID: pageID, rect: [72, 600, 272, 624], name: "Name")]),
      to: graph)
    let nameID = try #require(fieldID("Name", in: graph))
    guard case .dictionary(var field)? = graph.objects[nameID] else {
      Issue.record("field missing")
      return
    }
    field.removeValue(forKey: PDFName("AP"))
    graph.objects[nameID] = .dictionary(field)
    let report = FormSaveValidation.validate(in: graph, pageIDs: [pageID])
    #expect(report.findings.contains {
      $0.code == .appearanceMissing && $0.fieldName == "Name"
    })
  }

  @Test func richValueMismatchIsReported() throws {
    var (graph, pageID) = try page()
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 600, 372, 630], name: "Notes"),
        SetFormRichTextCommand(
          fieldName: "Notes",
          value: .plain("Hello rich", style: FormRichTextStyle(fontSize: 12))),
      ]), to: graph)
    let notesID = try #require(fieldID("Notes", in: graph))
    guard case .dictionary(var field)? = graph.objects[notesID] else {
      Issue.record("field missing")
      return
    }
    field[PDFName("V")] = .string(AnnotationText.encode("different plain text"))
    graph.objects[notesID] = .dictionary(field)
    let report = FormSaveValidation.validate(in: graph, pageIDs: [pageID])
    #expect(report.findings.contains {
      $0.code == .richValueMismatch && $0.fieldName == "Notes"
    })
  }

  @Test func calculationProblemsAreBlockingErrors() throws {
    var (graph, pageID) = try page()
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 600, 272, 624], name: "Total")
      ]), to: graph)
    // Hand-edited / imported rules can reference fields that do not exist; the
    // save check must surface that instead of failing silently.
    let totalID = try #require(fieldID("Total", in: graph))
    guard case .dictionary(var total)? = graph.objects[totalID] else {
      Issue.record("Total field missing")
      return
    }
    total[PDFName("SPDFCalculate")] = .dictionary([
      PDFName("Kind"): .name(PDFName("Sum")),
      PDFName("Fields"): .array([.string(AnnotationText.encode("MissingField"))]),
    ])
    graph.objects[totalID] = .dictionary(total)
    let report = FormSaveValidation.validate(in: graph, pageIDs: [pageID])
    #expect(report.findings.contains {
      $0.code == .calculationReferenceMissing && $0.severity == .error
    })
    #expect(report.hasBlockingErrors)
  }

  @Test func signedDocumentIsReportedWithoutTouchingTheSignature() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Signed/signed-one-page.pdf")
    let data = try Data(contentsOf: url)
    let parsed = try PDFParser.parse(data)
    let signaturesBefore = try PDFSignatureInventory.signatures(in: parsed.graph)
    #expect(!signaturesBefore.isEmpty)
    let report = FormSaveValidation.validate(in: parsed.graph, pageIDs: parsed.pageIDs)
    let finding = try #require(report.findings.first {
      $0.code == .signedDocumentWillBeInvalidated
    })
    #expect(finding.severity == .warning)
    #expect(finding.message.contains("signature"))
    #expect(try PDFSignatureInventory.signatures(in: parsed.graph).count == signaturesBefore.count)
  }

  @Test func reportJSONIsMachineReadable() throws {
    let (graph, pageID) = try page()
    let report = FormSaveValidation.validate(in: graph, pageIDs: [pageID])
    let json = try #require(FormSaveValidation.json(report))
    let parsed = try JSONSerialization.jsonObject(with: json)
    let object = try #require(parsed as? [String: Any])
    #expect(object["summary"] as? String == report.summary)
    #expect(object["findings"] is [[String: Any]])
  }
}
