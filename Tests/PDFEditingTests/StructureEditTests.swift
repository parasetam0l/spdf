import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P33-008–P33-014/P33-019 evidence: role, alternate-text, language, and
/// actual-text edits with explicit semantics; reading-order reordering that
/// never touches paint order; artifact marking; grouping/splitting; table
/// header scope; and independent re-validation of edited output.
@Suite("Structure edits")
struct StructureEditTests {
  private func tagged() throws -> (graph: PDFGraph, pageIDs: [PDFObjectID]) {
    let parsed = try PDFParser.parse(PDFFixtures.taggedPages())
    return (parsed.graph, parsed.pageIDs)
  }

  private func inventory(_ graph: PDFGraph, _ pageIDs: [PDFObjectID]) throws
    -> PDFStructureInventory
  {
    try PDFStructureInspector.inspect(in: graph, pageIDs: pageIDs)
  }

  @Test func roleAltLanguageAndActualTextEdits() throws {
    let (graph, pageIDs) = try tagged()
    let h1 = PDFObjectID(21)
    let paragraph = PDFObjectID(22)
    let figure = PDFObjectID(23)

    // P33-008: standard roles only.
    let roleEdited = try PDFEditingEngine.commit(
      PDFTransaction([SetStructureRoleCommand(elementID: h1, role: PDFName("H2"))]), to: graph)
    let roleInventory = try inventory(roleEdited, pageIDs)
    #expect(roleInventory.elements.first { $0.objectID == h1 }?.role == "H2")
    #expect(roleInventory.elements.first { $0.objectID == h1 }?.presentationRole == "heading")
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([SetStructureRoleCommand(elementID: h1, role: PDFName("MyCustom"))]),
        to: graph)
    }

    // P33-009: alternate text applies to figures and can be removed.
    let altEdited = try PDFEditingEngine.commit(
      PDFTransaction([SetStructureAltTextCommand(elementID: figure, alt: "A red square")]),
      to: graph)
    #expect(
      try inventory(altEdited, pageIDs).elements.first { $0.objectID == figure }?.alt
        == "A red square")
    let altCleared = try PDFEditingEngine.commit(
      PDFTransaction([SetStructureAltTextCommand(elementID: figure, alt: nil)]), to: altEdited)
    #expect(try inventory(altCleared, pageIDs).elements.first { $0.objectID == figure }?.alt == nil)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([SetStructureAltTextCommand(elementID: paragraph, alt: "not a figure")]),
        to: graph)
    }

    // P33-010: document-level and element-level language.
    let documentLanguage = try PDFEditingEngine.commit(
      PDFTransaction([SetStructureLanguageCommand(language: "de-DE")]), to: graph)
    #expect(try inventory(documentLanguage, pageIDs).language == "de-DE")
    let elementLanguage = try PDFEditingEngine.commit(
      PDFTransaction([SetStructureLanguageCommand(elementID: paragraph, language: "fr")]),
      to: graph)
    #expect(
      try inventory(elementLanguage, pageIDs).elements.first { $0.objectID == paragraph }?.language
        == "fr")
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([SetStructureLanguageCommand(language: "e")]), to: graph)
    }

    // P33-011: actual text changes only the accessibility text.
    let beforeText = try PageTextLayout.build(pageID: pageIDs[0], in: graph).clusters
      .map(\.text).joined()
    let actualEdited = try PDFEditingEngine.commit(
      PDFTransaction([SetStructureActualTextCommand(elementID: paragraph, actualText: "Replacement")]),
      to: graph)
    #expect(
      try inventory(actualEdited, pageIDs).elements.first { $0.objectID == paragraph }?.actualText
        == "Replacement")
    let afterText = try PageTextLayout.build(pageID: pageIDs[0], in: actualEdited).clusters
      .map(\.text).joined()
    #expect(beforeText == afterText)
  }

  @Test func reorderChangesReadingOrderOnly() throws {
    let (graph, pageIDs) = try tagged()
    let root = PDFObjectID(20)
    let beforeContent = try PageContent.load(pageID: pageIDs[0], in: graph).segments
      .flatMap(\.decoded)
    let reordered = try PDFEditingEngine.commit(
      PDFTransaction([ReorderStructureChildrenCommand(parentID: root, fromIndex: 0, toIndex: 1)]),
      to: graph)
    let roles = try inventory(reordered, pageIDs).elements.map(\.role)
    #expect(roles.prefix(2) == ["P", "H1"])
    let afterContent = try PageContent.load(pageID: pageIDs[0], in: reordered).segments
      .flatMap(\.decoded)
    #expect(beforeContent == afterContent)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReorderStructureChildrenCommand(parentID: root, fromIndex: 0, toIndex: 99)
        ]), to: graph)
    }
  }

  @Test func artifactGroupAndSplit() throws {
    let (graph, pageIDs) = try tagged()
    let root = PDFObjectID(20)
    let h1 = PDFObjectID(21)
    let paragraph = PDFObjectID(22)
    let figure = PDFObjectID(23)

    // P33-013: artifact marking clears alternate and actual text.
    let withActual = try PDFEditingEngine.commit(
      PDFTransaction([SetStructureActualTextCommand(elementID: paragraph, actualText: "hidden")]),
      to: graph)
    let artifact = try PDFEditingEngine.commit(
      PDFTransaction([MarkStructureArtifactCommand(elementID: paragraph)]), to: withActual)
    let artifactElement = try inventory(artifact, pageIDs).elements.first { $0.objectID == paragraph }
    #expect(artifactElement?.role == "Artifact")
    #expect(artifactElement?.actualText == nil)
    #expect(artifactElement?.presentationRole == "artifact")

    // P33-014: group H1 and Figure under a new Sect, then split it.
    let grouped = try PDFEditingEngine.commit(
      PDFTransaction([GroupStructureElementsCommand(parentID: root, elementIDs: [h1, figure])]),
      to: graph)
    let groupedInventory = try inventory(grouped, pageIDs)
    let group = try #require(groupedInventory.elements.first { $0.role == "Sect" })
    #expect(group.children.compactMap { child -> String? in
      if case .element(let nested) = child { return nested.role }
      return nil
    } == ["H1", "Figure"])
    #expect(groupedInventory.issues.isEmpty)

    guard let groupID = group.objectID else {
      Issue.record("Group has no object identity")
      return
    }
    let split = try PDFEditingEngine.commit(
      PDFTransaction([SplitStructureElementCommand(elementID: groupID, atIndex: 1)]), to: grouped)
    let splitInventory = try inventory(split, pageIDs)
    let halves = splitInventory.elements.filter { $0.role == "Sect" }
    #expect(halves.count == 2)
    #expect(halves.allSatisfy { $0.children.count == 1 })
    #expect(splitInventory.issues.isEmpty)
  }

  @Test func tableHeaderScope() throws {
    var graph = try tagged().graph
    // Add a minimal table: Table → TR → TH.
    graph.objects[PDFObjectID(70)] = .dictionary([
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(PDFName("Table")),
      PDFName("P"): .reference(PDFObjectID(20)),
      PDFName("K"): .array([.reference(PDFObjectID(71))]),
    ])
    graph.objects[PDFObjectID(71)] = .dictionary([
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(PDFName("TR")),
      PDFName("P"): .reference(PDFObjectID(70)),
      PDFName("K"): .array([.reference(PDFObjectID(72))]),
    ])
    graph.objects[PDFObjectID(72)] = .dictionary([
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(PDFName("TH")),
      PDFName("P"): .reference(PDFObjectID(71)),
      PDFName("K"): .array([]),
    ])
    if case .dictionary(var root)? = graph.objects[PDFObjectID(20)],
      case .array(var kids)? = root[PDFName("K")]
    {
      kids.append(.reference(PDFObjectID(70)))
      root[PDFName("K")] = .array(kids)
      graph.objects[PDFObjectID(20)] = .dictionary(root)
    }
    let pageIDs = try PDFPageTree.pageIDs(in: graph)

    let scoped = try PDFEditingEngine.commit(
      PDFTransaction([
        SetTableHeaderScopeCommand(elementID: PDFObjectID(72), scope: PDFName("Column"))
      ]), to: graph)
    guard case .dictionary(let th)? = scoped.objects[PDFObjectID(72)],
      case .dictionary(let attributes)? = th[PDFName("A")],
      case .name(let scope)? = attributes[PDFName("Scope")]
    else {
      Issue.record("Table header scope missing")
      return
    }
    #expect(scope == PDFName("Column"))
    #expect(attributes[PDFName("O")] == .name(PDFName("Table")))
    #expect(try inventory(scoped, pageIDs).issues.isEmpty)

    // A reference-shaped attribute object is mutated in place.
    var referenced = graph
    if case .dictionary(var th)? = referenced.objects[PDFObjectID(72)] {
      referenced.objects[PDFObjectID(73)] = .dictionary([
        PDFName("O"): .name(PDFName("Table"))
      ])
      th[PDFName("A")] = .reference(PDFObjectID(73))
      referenced.objects[PDFObjectID(72)] = .dictionary(th)
    }
    let referencedScoped = try PDFEditingEngine.commit(
      PDFTransaction([
        SetTableHeaderScopeCommand(elementID: PDFObjectID(72), scope: PDFName("Row"))
      ]), to: referenced)
    guard case .dictionary(let attributesObject)? = referencedScoped.objects[PDFObjectID(73)],
      case .name(let referencedScope)? = attributesObject[PDFName("Scope")]
    else {
      Issue.record("Referenced attribute object not updated")
      return
    }
    #expect(referencedScope == PDFName("Row"))

    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          SetTableHeaderScopeCommand(elementID: PDFObjectID(22), scope: PDFName("Column"))
        ]), to: graph)
    }
  }

  @Test func editedFixtureStillPassesIndependentValidation() throws {
    // P33-025 follow-up: role and alternate-text edits keep the document
    // PDF/UA-valid per veraPDF.
    guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/verapdf") else {
      return
    }
    let (graph, _) = try tagged()
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        SetStructureRoleCommand(elementID: PDFObjectID(22), role: PDFName("Span")),
        SetStructureAltTextCommand(elementID: PDFObjectID(23), alt: "An edited green square"),
        SetStructureLanguageCommand(elementID: PDFObjectID(22), language: "en-GB"),
      ]), to: graph)
    let data = try PDFWriter.write(edited)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-tagged-edited-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
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
  }
}
