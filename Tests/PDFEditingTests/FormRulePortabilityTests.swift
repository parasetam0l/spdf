import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// FRM-04 evidence: the calculation/format portability decision, rule and
/// action inventory, dependency-ordered evaluation and Freeze Static Results.
@Suite("Form rule portability")
struct FormRulePortabilityTests {
  private func fieldFixture() throws -> (graph: PDFGraph, pageID: PDFObjectID) {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    var graph = parsed.graph
    let pageID = parsed.pageIDs[0]
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 600, 272, 624], name: "Subtotal"),
        AddTextFieldCommand(pageID: pageID, rect: [72, 560, 272, 584], name: "Tax"),
        AddTextFieldCommand(pageID: pageID, rect: [72, 520, 272, 544], name: "Total"),
      ]), to: graph)
    return (graph, pageID)
  }

  private func fieldID(_ name: String, in graph: PDFGraph) -> PDFObjectID? {
    FormAuthoringSupport.findField(named: name, in: graph)
  }

  @Test func analysisClassifiesRulesAndImportedActionsWithoutMutation() throws {
    var (graph, pageID) = try fieldFixture()
    let totalID = try #require(fieldID("Total", in: graph))
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormFieldFormatCommand(
          fieldName: "Subtotal", format: .number(decimals: 2, prefix: "$", suffix: nil)),
        SetFormFieldCalculationCommand(
          fieldName: "Total", calculation: .sum(fields: ["Subtotal", "Tax"])),
      ]), to: graph)
    // Seed an imported JavaScript action that must never be executed or edited.
    guard case .dictionary(var totalField)? = graph.objects[totalID] else {
      Issue.record("Total field missing")
      return
    }
    totalField[PDFName("AA")] = .dictionary([
      PDFName("K"): .dictionary([
        PDFName("S"): .name(PDFName("JavaScript")),
        PDFName("JS"): .string(Data("app.alert('imported');".utf8)),
      ])
    ])
    graph.objects[totalID] = .dictionary(totalField)
    let before = graph

    let report = FormRulePortability.analyze(in: graph, pageIDs: [pageID])
    #expect(report.profileIdentifier == FormRulePortabilityDecision.profileIdentifier)
    #expect(report.fields.count == 3)
    let subtotal = try #require(report.fields.first { $0.fieldName == "Subtotal" })
    #expect(subtotal.classes.contains(.spdfOnlyFormat))
    #expect(subtotal.formatSummary?.contains("Number") == true)
    #expect(subtotal.importedActionSummaries.isEmpty)
    let total = try #require(report.fields.first { $0.fieldName == "Total" })
    #expect(total.classes.contains(.spdfOnlyCalculation))
    #expect(total.classes.contains(.importedScriptPreserved))
    #expect(total.importedActionSummaries.contains { $0.contains("JavaScript") })
    #expect(total.disclosure.contains("never executes"))
    let tax = try #require(report.fields.first { $0.fieldName == "Tax" })
    #expect(tax.classes == [.staticValue])
    #expect(report.hasAppSpecificRules)
    #expect(report.hasImportedActions)
    #expect(report.disclosures.contains { $0.contains("JavaScript") })
    // Analysis is read-only: the seeded action and the rules are unchanged.
    #expect(graph == before)
  }

  @Test func decisionDocumentsClaimedAndUnclaimedProfiles() throws {
    #expect(FormRulePortabilityDecision.claimedProfiles.count == 3)
    #expect(FormRulePortabilityDecision.notClaimed.contains {
      $0.contains("External-reader recalculation")
    })
    #expect(FormRulePortabilityDecision.summary.contains("never authors or executes"))

    let report = FormRulePortabilityReport(
      profileIdentifier: FormRulePortabilityDecision.profileIdentifier,
      fields: [], acroFormScriptCount: 0, acroFormDefaultAppearancePresent: true,
      summary: "empty", disclosures: FormRulePortabilityDecision.claimedProfiles)
    let json = try #require(FormRulePortability.json(report))
    let parsed = try JSONSerialization.jsonObject(with: json)
    let object = try #require(parsed as? [String: Any])
    #expect(object["profile"] as? String == FormRulePortabilityDecision.profileIdentifier)
    #expect((object["notClaimed"] as? [String])?.count == FormRulePortabilityDecision.notClaimed.count)
  }

  @Test func calculationEngineFormatsValuesInDependencyOrder() throws {
    var (graph, pageID) = try fieldFixture()
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormTextCommand(fieldName: "Subtotal", text: "10"),
        SetFormTextCommand(fieldName: "Tax", text: "2.5"),
        SetFormFieldFormatCommand(
          fieldName: "Total", format: .number(decimals: 2, prefix: nil, suffix: nil)),
        SetFormFieldCalculationCommand(
          fieldName: "Total", calculation: .sum(fields: ["Subtotal", "Tax"])),
        AddTextFieldCommand(pageID: pageID, rect: [72, 480, 272, 504], name: "Grand"),
        SetFormFieldFormatCommand(
          fieldName: "Grand", format: .number(decimals: 1, prefix: nil, suffix: nil)),
        SetFormFieldCalculationCommand(
          fieldName: "Grand", calculation: .sum(fields: ["Total", "Tax"])),
      ]), to: graph)
    let values = try FormCalculationEngine.evaluate(in: graph, pageIDs: [pageID])
    let total = try #require(values.first { $0.fieldName == "Total" })
    #expect(abs(total.numericValue - 12.5) < 1e-9)
    #expect(total.formattedValue == "12.50")
    let grand = try #require(values.first { $0.fieldName == "Grand" })
    #expect(abs(grand.numericValue - 15.0) < 1e-9)
    #expect(grand.formattedValue == "15.0")
  }

  @Test func calculationEngineRefusesCycles() throws {
    var (graph, pageID) = try fieldFixture()
    let subtotalID = try #require(fieldID("Subtotal", in: graph))
    let taxID = try #require(fieldID("Tax", in: graph))
    for (id, references) in [(subtotalID, ["Tax"]), (taxID, ["Subtotal"])] {
      guard case .dictionary(var field)? = graph.objects[id] else { continue }
      field[PDFName("SPDFCalculate")] = .dictionary(
        FormFieldFormatting.calculateDictionary(.sum(fields: references)))
      graph.objects[id] = .dictionary(field)
    }
    #expect(throws: PDFError.self) {
      _ = try FormCalculationEngine.evaluate(in: graph, pageIDs: [pageID])
    }
  }

  @Test func freezeWritesStaticValuesAndStripsRules() throws {
    var (graph, pageID) = try fieldFixture()
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormTextCommand(fieldName: "Subtotal", text: "10"),
        SetFormTextCommand(fieldName: "Tax", text: "2.5"),
        SetFormFieldFormatCommand(
          fieldName: "Total", format: .number(decimals: 2, prefix: "$", suffix: nil)),
        SetFormFieldCalculationCommand(
          fieldName: "Total", calculation: .sum(fields: ["Subtotal", "Tax"])),
      ]), to: graph)
    let frozen = try PDFEditingEngine.commit(
      PDFTransaction([FreezeFormResultsCommand()]), to: graph)
    let fields = try FormInventory.fields(in: frozen, pageIDs: [pageID])
    let total = try #require(fields.first { $0.name == "Total" })
    #expect(total.stringValue == "$12.50")
    guard let totalID = fieldID("Total", in: frozen),
      case .dictionary(let dictionary)? = frozen.objects[totalID]
    else {
      Issue.record("Frozen field missing")
      return
    }
    #expect(dictionary[PDFName("SPDFCalculate")] == nil)
    #expect(dictionary[PDFName("SPDFFormat")] == nil)
    #expect(dictionary[PDFName("DV")] != nil)
    // The unrelated field keeps its value and no script was authored.
    let subtotal = try #require(fields.first { $0.name == "Subtotal" })
    #expect(subtotal.stringValue == "10")
    let frozenReport = FormRulePortability.analyze(in: frozen, pageIDs: [pageID])
    #expect(!frozenReport.hasAppSpecificRules)
    #expect(!frozenReport.hasImportedActions)
    // The frozen field is now a static value in the portability report.
    let frozenTotal = try #require(frozenReport.fields.first { $0.fieldName == "Total" })
    #expect(frozenTotal.classes == [.staticValue])
  }

  @Test func freezeRefusesDocumentsWithoutRules() throws {
    var (graph, pageID) = try fieldFixture()
    graph = try PDFEditingEngine.commit(
      PDFTransaction([SetFormTextCommand(fieldName: "Total", text: "5")]), to: graph)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([FreezeFormResultsCommand()]), to: graph)
    }
    _ = pageID
  }

  @Test func authoredCommandsNeverAddDocumentScripts() throws {
    var (graph, pageID) = try fieldFixture()
    let before = try scriptInventory(in: graph, pageIDs: [pageID])
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormFieldFormatCommand(
          fieldName: "Subtotal", format: .number(decimals: 1, prefix: nil, suffix: nil)),
        SetFormFieldCalculationCommand(
          fieldName: "Total", calculation: .sum(fields: ["Subtotal", "Tax"])),
        SetFormTextCommand(fieldName: "Subtotal", text: "4"),
        FreezeFormResultsCommand(),
      ]), to: graph)
    let after = try scriptInventory(in: graph, pageIDs: [pageID])
    #expect(before == after)
    #expect(after.isEmpty)
  }

  private func scriptInventory(in graph: PDFGraph, pageIDs: [PDFObjectID]) throws -> [String] {
    var inventory: [String] = []
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    for field in fields {
      guard let fieldID = field.fieldID, case .dictionary(let dictionary)? = graph.objects[fieldID]
      else { continue }
      inventory += FormRulePortability.importedActions(in: dictionary)
    }
    if let acroForm = FormInventory.acroFormDictionary(in: graph) {
      inventory += FormRulePortability.importedActions(in: acroForm)
    }
    return inventory.sorted()
  }
}
