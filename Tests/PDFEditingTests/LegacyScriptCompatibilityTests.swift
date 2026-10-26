import Foundation
import PDFCore
import PDFEditing
import PDFFixtures
import Testing

/// SPC-06: the legacy Acrobat JavaScript decision - inventory, declared
/// declarative equivalents, controlled operations and explicit neutralization.
struct LegacyScriptCompatibilityTests {
  private func graph() throws -> (PDFGraph, [PDFObjectID]) {
    let graph = try CompatibilityFixtures.scriptedDocument()
    return (graph, try CompatibilityFixtures.pageIDs(of: graph))
  }

  @Test func inventoryFindsEveryOwnerAndClassifiesOperations() throws {
    let (graph, pageIDs) = try graph()
    let inventory = LegacyScriptCompatibility.inventory(in: graph, pageIDs: pageIDs)
    #expect(inventory.hasScripts)
    #expect(inventory.actions.contains { $0.location == .catalog })
    #expect(inventory.actions.contains { $0.location == .page(index: 0) })
    #expect(inventory.actions.contains {
      if case .annotation(let pageIndex, _) = $0.location { return pageIndex == 0 }
      return false
    })
    #expect(inventory.actions.contains {
      if case .field(let name) = $0.location { return name == "Total" }
      return false
    })
    #expect(inventory.scriptedFieldNames == ["Total"])
    #expect(inventory.hasScriptedCalculationOrder)
    #expect(inventory.automaticActions.contains { $0.trigger == .documentOpen })
    #expect(inventory.automaticActions.contains { $0.trigger == .willSave })
    #expect(inventory.actions.contains { $0.isDocumentWide })
    #expect(inventory.controlledOperations.contains(.networkAccess))
    #expect(inventory.controlledOperations.contains(.applicationLaunchOrExecution))
    #expect(inventory.controlledOperations.contains(.fileSystemAccess))
    let javascript = inventory.javascriptActions
    #expect(!javascript.isEmpty)
    #expect(javascript.allSatisfy { $0.scriptDigest?.count == 64 })
    #expect(javascript.allSatisfy { ($0.scriptByteCount ?? 0) > 0 })
    let description = String(describing: inventory)
    #expect(!description.contains("launchURL"))
    #expect(!description.contains("importDataObject"))
    #expect(inventory.actions.contains { $0.kind == "URI" && !$0.isJavaScript })
  }

  @Test func policyDeclaresIsolationAndDeclarativeEquivalents() throws {
    let (graph, pageIDs) = try graph()
    let report = LegacyScriptCompatibility.report(in: graph, pageIDs: pageIDs)
    #expect(report.profileIdentifier == "spdf-legacy-js-isolated-v1")
    #expect(report.isControlled)
    #expect(report.removalAvailable)
    #expect(report.hasControlledOperations)
    let calculate = try #require(report.eventDecisions.first { $0.trigger == .calculate })
    #expect(calculate.supported)
    #expect(calculate.declarativeEquivalent.contains("/SPDFCalculate"))
    let format = try #require(report.eventDecisions.first { $0.trigger == .format })
    #expect(format.supported)
    let keystroke = try #require(report.eventDecisions.first { $0.trigger == .keystroke })
    #expect(!keystroke.supported)
    #expect(report.disclosures.contains { $0.contains("never evaluates") })
    #expect(report.disclosures.contains { $0.contains("File-system access") })
    #expect(report.summary.contains("spdf-legacy-js-isolated-v1"))
    #expect(report.summary.contains("scripts are inert"))
  }

  @Test func removalCommandStripsJavaScriptAndPreservesOtherActions() throws {
    let (original, pageIDs) = try graph()
    let command = RemoveJavaScriptActionsCommand()
    #expect(command.requiresFullRewriteOnSave)
    try command.validate(in: original)
    let annotationsBefore = try AnnotationInventory.annotations(
      in: original, pageID: pageIDs[0]).count
    let cleaned = try command.apply(to: original)
    let after = LegacyScriptCompatibility.inventory(in: cleaned, pageIDs: pageIDs)
    #expect(!after.hasScripts)
    #expect(!after.actions.contains { $0.isJavaScript })
    #expect(!after.hasScriptedCalculationOrder)
    #expect(after.scriptedFieldNames.isEmpty)
    #expect(after.actions.contains { $0.kind == "URI" })
    let annotationsAfter = try AnnotationInventory.annotations(
      in: cleaned, pageID: pageIDs[0]).count
    #expect(annotationsAfter == annotationsBefore)
    let fields = try FormInventory.fields(in: cleaned, pageIDs: pageIDs)
    #expect(fields.first { $0.name == "Total" }?.stringValue == "0")
    let written = try PDFWriter.write(cleaned)
    let parsed = try PDFParser.parse(written)
    #expect(parsed.pageIDs.count == 2)
    #expect(throws: PDFError.self) { try command.validate(in: cleaned) }
    // The original graph is untouched.
    #expect(LegacyScriptCompatibility.inventory(
      in: original, pageIDs: pageIDs).hasScripts)
  }

  @Test func benignScriptStillDeclaredButNoControlledOperations() throws {
    let graph = try CompatibilityFixtures.documentWithOpenActionScript()
    let pageIDs = try CompatibilityFixtures.pageIDs(of: graph)
    let inventory = LegacyScriptCompatibility.inventory(in: graph, pageIDs: pageIDs)
    #expect(inventory.hasScripts)
    #expect(inventory.controlledOperations.isEmpty)
    #expect(inventory.automaticActions.contains { $0.trigger == .documentOpen })
    let report = LegacyScriptCompatibility.report(in: graph, pageIDs: pageIDs)
    #expect(!report.hasControlledOperations)
    #expect(report.disclosures.contains { $0.contains("never compiled") })
  }

  @Test func documentWithoutActionsReportsExplicitly() throws {
    let data = try PDFFixtures.onePage()
    let parsed = try PDFParser.parse(data)
    let inventory = LegacyScriptCompatibility.inventory(
      in: parsed.graph, pageIDs: parsed.pageIDs)
    #expect(!inventory.hasScripts)
    #expect(!inventory.hasAnyAction)
    let report = LegacyScriptCompatibility.report(
      in: parsed.graph, pageIDs: parsed.pageIDs)
    #expect(report.summary.contains("No document JavaScript"))
    #expect(!report.removalAvailable)
    #expect(throws: PDFError.self) {
      try RemoveJavaScriptActionsCommand().validate(in: parsed.graph)
    }
  }

  @Test func malformedActionEntriesAreSkippedSafely() throws {
    var graph = try PDFFixtures.graph(pages: 1)
    var (rootID, catalogValue) = try CompatibilityFixtures.catalog(of: graph)
    catalogValue[PDFName("OpenAction")] = .null
    catalogValue[PDFName("Names")] = .dictionary([
      PDFName("JavaScript"): .dictionary([
        PDFName("Names"): .array([
          .string(Data("broken".utf8)), .integer(1),
        ])
      ])
    ])
    graph.objects[rootID] = .dictionary(catalogValue)
    let pageIDs = try CompatibilityFixtures.pageIDs(of: graph)
    let inventory = LegacyScriptCompatibility.inventory(in: graph, pageIDs: pageIDs)
    #expect(!inventory.hasScripts)
    #expect(throws: PDFError.self) {
      try RemoveJavaScriptActionsCommand().validate(in: graph)
    }
  }
}
