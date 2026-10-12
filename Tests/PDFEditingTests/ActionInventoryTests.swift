import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P08-019/P22-024 evidence: document, page, and annotation actions are
/// inventoried with their triggers, and scanning never executes anything.
@Suite("Action inventory")
struct ActionInventoryTests {
  @Test func catalogPageAndAnnotationActionsAreInventoried() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    var graph = parsed.graph
    let pageIDs = parsed.pageIDs
    guard case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[rootID]
    else {
      Issue.record("Fixture catalog is missing")
      return
    }
    catalog[PDFName("OpenAction")] = .dictionary([
      PDFName("S"): .name(PDFName("JavaScript")),
      PDFName("JS"): .string(Data("app.alert('hi')".utf8)),
      PDFName("Next"): .dictionary([PDFName("S"): .name(PDFName("Launch"))]),
    ])
    catalog[PDFName("AA")] = .dictionary([
      PDFName("WC"): .dictionary([PDFName("S"): .name(PDFName("JavaScript"))])
    ])
    graph.objects[rootID] = .dictionary(catalog)
    guard case .dictionary(var page)? = graph.objects[pageIDs[0]] else {
      Issue.record("Fixture page is missing")
      return
    }
    page[PDFName("AA")] = .dictionary([
      PDFName("O"): .dictionary([PDFName("S"): .name(PDFName("Launch"))])
    ])
    graph.objects[pageIDs[0]] = .dictionary(page)

    let linked = try PDFEditingEngine.commit(
      PDFTransaction([
        AddLinkCommand(
          pageID: pageIDs[0], rect: [10, 10, 60, 30], target: .uri("https://example.com"))
      ]), to: graph)
    let actions = ActionInventory.actions(in: linked, pageIDs: pageIDs)
    #expect(actions.count == 5)
    #expect(actions[0].kind == PDFName("JavaScript"))
    #expect(actions[0].trigger == PDFName("OpenAction"))
    #expect(actions[0].location == .catalog)
    #expect(actions[0].isAutomatic && actions[0].isJavaScript)
    #expect(actions[1].kind == PDFName("Launch"))
    #expect(actions[1].isAutomatic && actions[1].isLaunch)
    #expect(actions[2].trigger == PDFName("WC"))
    #expect(actions[2].isJavaScript)
    let pageAction = actions.first { $0.location == .page(index: 0) }
    #expect(pageAction?.kind == PDFName("Launch"))
    #expect(pageAction?.isAutomatic == true)
    let link = actions.first { $0.location == .annotation(pageIndex: 0, annotationIndex: 0) }
    #expect(link?.kind == PDFName("URI"))
    #expect(link?.isAutomatic == false)
    #expect(link?.isURI == true)

    // Scanning is read-only and deterministic.
    #expect(ActionInventory.actions(in: linked, pageIDs: pageIDs) == actions)
    #expect(try PDFParser.parse(PDFWriter.write(linked)).graph == linked)
  }

  @Test func actionFreeDocumentsReportNothing() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    #expect(ActionInventory.actions(in: parsed.graph, pageIDs: parsed.pageIDs).isEmpty)
  }
}
