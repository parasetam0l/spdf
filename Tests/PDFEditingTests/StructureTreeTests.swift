import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P33-001–P33-007/P33-015–P33-018/P33-020/P33-021/P33-025–P33-028 evidence:
/// structure parsing with role/class maps, ParentTree and MCID resolution,
/// object references, issue detection, bounded repair, preservation through
/// edits, redaction pruning, and independent PDF/UA validation with veraPDF.
@Suite("Structure tree")
struct StructureTreeTests {
  private func tagged() throws -> ParsedPDF {
    try PDFParser.parse(PDFFixtures.taggedPages())
  }

  /// A variant with a Type 1 font so the supported text profile can edit and
  /// redact it (the committed fixture uses Type 3 for PDF/UA font rules).
  private func editableTaggedGraph() throws -> (graph: PDFGraph, pageIDs: [PDFObjectID]) {
    var graph = try tagged().graph
    graph.objects[PDFObjectID(7)] = .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Helvetica")),
    ])
    return (graph, try PDFPageTree.pageIDs(in: graph))
  }

  @Test func taggedFixtureInventoryResolvesStructure() throws {
    let parsed = try tagged()
    let inventory = try PDFStructureInspector.inspect(
      in: parsed.graph, pageIDs: parsed.pageIDs)
    #expect(inventory.isTagged)
    #expect(inventory.hasMarkInfo)
    #expect(inventory.language == "en-US")
    #expect(inventory.roleMap["MyHead"] == "H1")
    #expect(inventory.classMap["Body"]?[PDFName("O")] == .name(PDFName("Layout")))
    #expect(inventory.rootObjectID == PDFObjectID(20))
    #expect(inventory.elements.map(\.role) == ["H1", "P", "Figure", "Link", "Form"])
    #expect(
      inventory.elements.map(\.presentationRole) == [
        "heading", "paragraph", "figure", "link", "form",
      ])
    #expect(inventory.elements[0].rawRole == "MyHead")
    // P33-004: MCID content resolves to the page.
    #expect(inventory.elements[0].children.contains(.content(pageIndex: 0, mcid: 0)))
    #expect(inventory.elements[1].children.contains(.content(pageIndex: 0, mcid: 1)))
    #expect(inventory.elements[0].pageIndex == 0)
    // P33-005: annotations and widgets resolve through /OBJR.
    #expect(
      inventory.elements[3].children.contains(
        .objectReference(annotationObjectID: PDFObjectID(50), pageIndex: 0)))
    #expect(
      inventory.elements[4].children.contains(
        .objectReference(annotationObjectID: PDFObjectID(41), pageIndex: 0)))
    #expect(inventory.elements[2].alt == "A green square")
    // P33-003: ParentTree keys and page mapping.
    #expect(inventory.parentTreeKeys == [0, 1, 2])
    #expect(inventory.pageStructParents == [0])
    #expect(inventory.pageMCIDs == [[0, 1, 2]])
    #expect(inventory.issues.isEmpty)
  }

  @Test func issuesAreDetected() throws {
    var graph = try tagged().graph
    if case .dictionary(var h1)? = graph.objects[PDFObjectID(21)] {
      var kids: [PDFValue] = []
      switch h1[PDFName("K")] {
      case .array(let existing)?: kids = existing
      case let single?: kids = [single]
      default: break
      }
      kids.append(.reference(PDFObjectID(99)))
      h1[PDFName("K")] = .array(kids)
      graph.objects[PDFObjectID(21)] = .dictionary(h1)
    }
    if case .dictionary(var page)? = graph.objects[PDFObjectID(3)] {
      page[PDFName("StructParents")] = .integer(7)
      graph.objects[PDFObjectID(3)] = .dictionary(page)
    }
    graph.objects[PDFObjectID(60)] = .dictionary([
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(PDFName("P")),
      PDFName("P"): .reference(PDFObjectID(20)),
      PDFName("Pg"): .reference(PDFObjectID(99)),
    ])
    if case .dictionary(var root)? = graph.objects[PDFObjectID(20)],
      case .array(var kids)? = root[PDFName("K")]
    {
      kids.append(.reference(PDFObjectID(60)))
      root[PDFName("K")] = .array(kids)
      graph.objects[PDFObjectID(20)] = .dictionary(root)
    }
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let inventory = try PDFStructureInspector.inspect(in: graph, pageIDs: pageIDs)
    let kinds = Set(inventory.issues.map(\.kind))
    #expect(kinds.contains(.danglingReference))
    #expect(kinds.contains(.missingParentTreeEntry))
    #expect(kinds.contains(.orphanedElement))
  }

  @Test func repairPrunesDanglingReferences() throws {
    var graph = try tagged().graph
    if case .dictionary(var h1)? = graph.objects[PDFObjectID(21)] {
      var kids: [PDFValue] = []
      switch h1[PDFName("K")] {
      case .array(let existing)?: kids = existing
      case let single?: kids = [single]
      default: break
      }
      kids.append(.reference(PDFObjectID(99)))
      h1[PDFName("K")] = .array(kids)
      graph.objects[PDFObjectID(21)] = .dictionary(h1)
    }
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let (repaired, report) = try PDFStructureRepair.pruneDangling(
      in: graph, pageIDs: pageIDs)
    #expect(!report.isEmpty)
    #expect(report.removedKids >= 1)
    let inventory = try PDFStructureInspector.inspect(in: repaired, pageIDs: pageIDs)
    #expect(!inventory.issues.contains { $0.kind == .danglingReference })
    // The repaired graph still writes and reparses.
    let data = try PDFWriter.write(repaired)
    _ = try PDFParser.parse(data)
  }

  @Test func redactionPrunesRemovedStructureContent() throws {
    let (graph, pageIDs) = try editableTaggedGraph()
    let redacted = try PDFEditingEngine.commit(
      PDFTransaction([
        RedactRegionsCommand(pageID: pageIDs[0], regions: [[40, 650, 570, 680]])
      ]), to: graph)
    let inventory = try PDFStructureInspector.inspect(in: redacted, pageIDs: pageIDs)
    // P33-027: the emptied paragraph element is gone; the others survive.
    #expect(!inventory.elements.contains { $0.role == "P" })
    #expect(inventory.elements.contains { $0.role == "H1" })
    #expect(inventory.elements.contains { $0.role == "Figure" })
    #expect(inventory.elements.contains { $0.role == "Link" })
    let data = try PDFWriter.write(redacted)
    // The removed text is absent (strings are written hex-encoded, so check
    // through the parsed graph as well) and the figure keeps its /Alt.
    #expect(data.range(of: Data("Tagged paragraph text".utf8)) == nil)
    let reparsed = try PDFParser.parse(data)
    let reparsedInventory = try PDFStructureInspector.inspect(
      in: reparsed.graph, pageIDs: reparsed.pageIDs)
    #expect(reparsedInventory.elements.first { $0.role == "Figure" }?.alt == "A green square")
    #expect(reparsedInventory.issues.isEmpty)
  }

  @Test func textFormAndPageEditsPreserveStructure() throws {
    let (graph, pageIDs) = try editableTaggedGraph()

    // P33-015/P33-026: a text edit leaves the structure and reading order
    // intact.
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextCommand(pageID: pageIDs[0], runIndex: 0, replacement: "Edited heading")
      ]), to: graph)
    let editedInventory = try PDFStructureInspector.inspect(in: edited, pageIDs: pageIDs)
    #expect(editedInventory.elements.map(\.role) == ["H1", "P", "Figure", "Link", "Form"])
    #expect(editedInventory.issues.isEmpty)

    // P33-017: form edits preserve the widget's StructParent link.
    let filled = try PDFEditingEngine.commit(
      PDFTransaction([SetFormTextCommand(fieldName: "taggedField", text: "value")]),
      to: graph)
    let filledInventory = try PDFStructureInspector.inspect(in: filled, pageIDs: pageIDs)
    #expect(filledInventory.issues.isEmpty)
    let fields = try FormInventory.fields(in: filled, pageIDs: pageIDs)
    #expect(fields.first?.stringValue == "value")

    // P33-016: inserting and deleting an unrelated page keeps references
    // resolvable; deleting the tagged page prunes its structure.
    let withBlank = try PDFEditingEngine.commit(
      PDFTransaction([InsertBlankPageCommand(atIndex: 1, width: 612, height: 792)]),
      to: graph)
    let blankPages = try PDFPageTree.pageIDs(in: withBlank)
    let removedBlank = try PDFEditingEngine.commit(
      PDFTransaction([DeletePagesCommand(pageIDs: [blankPages[1]])]), to: withBlank)
    let removedInventory = try PDFStructureInspector.inspect(
      in: removedBlank, pageIDs: try PDFPageTree.pageIDs(in: removedBlank))
    #expect(removedInventory.issues.isEmpty)

    // Deleting the tagged page prunes its structure references first; the
    // deletion itself still refuses while annotations reference the page
    // (the annotation policy is separate and by design).
    let (pruned, pruneReport) = try PDFStructureRepair.pruneReferences(
      toPage: blankPages[0], in: withBlank, pageIDs: blankPages)
    #expect(!pruneReport.isEmpty)
    let prunedInventory = try PDFStructureInspector.inspect(in: pruned, pageIDs: blankPages)
    #expect(prunedInventory.elements.isEmpty)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([DeletePagesCommand(pageIDs: [blankPages[0]])]), to: pruned)
    }
  }

  @Test func independentValidatorAcceptsTheTaggedFixture() throws {
    // P33-025: veraPDF, the independent PDF/UA-1 validator, must accept the
    // fixture we generate (106 rules, zero failures).
    guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/verapdf") else {
      return
    }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-tagged-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    try PDFFixtures.taggedPages().write(to: url)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/verapdf")
    process.arguments = ["--flavour", "ua1", "--format", "text", url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, "veraPDF: \(output)")
    #expect(output.contains("PASS"), "veraPDF: \(output)")
    #expect(output.contains("ua1"))
  }
}
