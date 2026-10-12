import Foundation
import PDFCore
import PDFFixtures
@testable import PDFEditing
import Testing

/// P38-014–P38-022: hardening budgets, sanity checks, inert resources,
/// attachment path safety, and conservative repair with provenance and edit
/// gating.
@Suite("Hardening")
struct HardeningTests {
  // MARK: - P38-014

  @Test func budgetsBoundSuspiciousDocuments() throws {
    let budget = HardeningBudget.hostile
    #expect(budget.limits.fileBytes == 8 * 1_024 * 1_024)
    #expect(budget.limits.objects == 20_000)
    #expect(budget.limits.nesting <= 256)
    #expect(budget.parseMilliseconds == 2_000)
    #expect(HardeningBudget.untrusted.limits.fileBytes == 64 * 1_024 * 1_024)

    // A file beyond the budget fails explicitly and quickly.
    var oversized = Data("%PDF-1.7\n".utf8)
    oversized.append(Data(repeating: 0x20, count: budget.limits.fileBytes + 1_024))
    let start = ContinuousClock.now
    do {
      _ = try PDFParser.parse(oversized, limits: budget.limits)
      Issue.record("An over-budget file parsed")
    } catch let error as PDFError {
      #expect(error.kind == .limitExceeded)
    }
    let elapsed = ContinuousClock.now - start
    let milliseconds =
      Int(elapsed.components.seconds * 1000)
      + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    #expect(milliseconds < budget.parseMilliseconds)

    // A suspicious-but-within-budget document parses within its budget.
    let parsed = try PDFParser.parse(PDFFixtures.onePage(), limits: budget.limits)
    #expect(parsed.pageIDs.count == 1)
  }

  // MARK: - P38-018

  @Test func sanityCheckDetectsSparseIndicesAndCounts() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let pageIDs = parsed.pageIDs

    // A sparse object index (high numbers, few objects).
    var sparse = parsed.graph
    sparse.objects[PDFObjectID(50_000)] = .integer(1)
    let sparseReport = PDFSanityReport.check(sparse, pageIDs: pageIDs)
    #expect(sparseReport.isSuspicious)
    #expect(sparseReport.findings.contains { $0.kind == .sparseObjectIndex })
    #expect(sparseReport.report().contains("sparse"))

    // An object number beyond the configured limit.
    var outOfRange = parsed.graph
    outOfRange.objects[PDFObjectID(900_000)] = .integer(1)
    let outOfRangeReport = PDFSanityReport.check(outOfRange, pageIDs: pageIDs)
    #expect(outOfRangeReport.findings.contains { $0.kind == .objectNumberOutOfRange })

    // A page tree that declares more pages than are reachable.
    var mismatched = parsed.graph
    if case .reference(let catalogID)? = mismatched.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = mismatched.objects[catalogID],
      case .reference(let pagesID)? = catalog[PDFName("Pages")],
      case .dictionary(var pages)? = mismatched.objects[pagesID]
    {
      pages[PDFName("Count")] = .integer(9)
      mismatched.objects[pagesID] = .dictionary(pages)
    }
    let mismatchReport = PDFSanityReport.check(mismatched, pageIDs: pageIDs)
    #expect(mismatchReport.findings.contains { $0.kind == .pageCountMismatch })

    // Page and object counts beyond the budget.
    let tight = HardeningBudget(suspiciousObjects: 1, suspiciousPages: 0)
    let tightReport = PDFSanityReport.check(parsed.graph, pageIDs: pageIDs, budget: tight)
    #expect(tightReport.findings.contains { $0.kind == .unreasonablePageCount })
    #expect(tightReport.findings.contains { $0.kind == .unreasonableObjectCount })

    // A clean document reports nothing.
    let clean = PDFSanityReport.check(parsed.graph, pageIDs: pageIDs)
    #expect(!clean.isSuspicious)
    #expect(clean.report().contains("no suspicious"))
  }

  // MARK: - P38-016

  @Test func documentActionsStayInert() throws {
    var graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let script = "app.alert('marker'); this.exportDataObject({cName:'x'});"
    if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    {
      catalog[PDFName("OpenAction")] = .dictionary([
        PDFName("S"): .name(PDFName("JavaScript")),
        PDFName("JS"): .string(Data(script.utf8)),
      ])
      graph.objects[catalogID] = .dictionary(catalog)
    }
    if case .dictionary(var page)? = graph.objects[pageID] {
      page[PDFName("AA")] = .dictionary([
        PDFName("O"): .dictionary([PDFName("S"): .name(PDFName("Launch"))])
      ])
      graph.objects[pageID] = .dictionary(page)
    }
    let before = graph
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let actions = ActionInventory.actions(in: graph, pageIDs: pageIDs)
    #expect(actions.contains { $0.isJavaScript })
    #expect(actions.contains { $0.isLaunch })
    // Analysis never executes or rewrites the script: the graph is unchanged
    // and the payload is still verbatim text.
    #expect(graph == before)
    if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID],
      case .dictionary(let action)? = catalog[PDFName("OpenAction")],
      case .string(let data)? = action[PDFName("JS")]
    {
      #expect(String(decoding: data, as: UTF8.self) == script)
    } else {
      Issue.record("The script payload changed")
    }
    // Rendering-side analysis (layout) does not touch actions either.
    _ = try? PageTextLayout.build(pageID: pageID, in: graph)
    #expect(graph == before)
  }

  // MARK: - P38-017

  @Test func attachmentNamesNeverEscapeTheDestination() throws {
    let hostile = [
      "../../etc/passwd", "..\\..\\windows\\system32", "/absolute/path", "\\absolute",
      "C:drive.txt", "~/Library/evil", "..", ".", "", " ", "a/../../b",
      "nul\u{0000}byte.txt", "newline\nname.txt", "tab\tname.txt", "colon:name.txt",
      String(repeating: "a", count: 600), "...hidden", "..hidden", "trailing.",
      "trailing ", " leading", "quote\"name", "star*name", "question?name",
      "pipe|name", "less<name", "greater>name", "semi;name", "comma,name",
      "equals=name", "at@name", "dollar$name", "percent%name", "hash#name",
      "amp&name", "paren(name)", "brace{name}", "bracket[name]", "tilde~name",
      "backtick`name", "bang!name", "plus+name",
    ]
    // Deterministic extra names with the same hostile alphabet.
    var rng = ParserFuzzTests.SplitMix64(seed: 0x5EED_0011)
    let alphabet = Array("ab/\\:.~ \u{0000}\n\t*?\"<>|")
    var generated: [String] = []
    for _ in 0..<200 {
      let length = rng.int(1..<40)
      generated.append(String((0..<length).map { _ in alphabet[rng.int(0..<alphabet.count)] }))
    }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-names-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let resolvedRoot = directory.resolvingSymlinksInPath().path

    for name in hostile + generated {
      let safe = PDFAttachmentExport.safeFileName(name)
      #expect(!safe.isEmpty, "empty for \(name.debugDescription)")
      #expect(!safe.contains("/"), "slash in \(safe.debugDescription)")
      #expect(!safe.contains("\\"), "backslash in \(safe.debugDescription)")
      #expect(!safe.contains("\u{0000}"), "NUL in \(safe.debugDescription)")
      #expect(!safe.hasPrefix("."), "leading dot in \(safe.debugDescription)")
      #expect(safe.count <= 255, "too long: \(safe.count)")
      // A write with the sanitized name lands inside the destination.
      let url = directory.appendingPathComponent(safe)
      #expect(url.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot))
      try Data("x".utf8).write(to: url, options: .atomic)
      try FileManager.default.removeItem(at: url)
    }
  }

  // MARK: - P38-019/P38-020/P38-021

  /// Corrupts the startxref pointer and the first xref entry while leaving the
  /// objects intact.
  private func corruptCrossReference(_ data: Data) -> Data {
    var text = String(decoding: data, as: UTF8.self)
    if let range = text.range(of: "startxref") {
      let tail = text[range.upperBound...]
      if let digits = tail.range(of: "\\d+", options: .regularExpression) {
        text.replaceSubrange(
          digits, with: String(repeating: "9", count: text[digits].count))
      }
    }
    if let range = text.range(of: "xref") {
      let after = text[range.upperBound...]
      if let firstEntry = after.range(of: "\\d{10} \\d{5} n", options: .regularExpression) {
        text.replaceSubrange(firstEntry, with: "0000000000 65535 n")
      }
    }
    return Data(text.utf8)
  }

  /// A fixture whose xref and startxref are corrupted but whose objects are
  /// intact.
  private func damagedFixture(extraDamage: (inout String) -> Void = { _ in }) -> Data {
    var text = String(decoding: try! PDFFixtures.onePage(), as: UTF8.self)
    extraDamage(&text)
    return corruptCrossReference(Data(text.utf8))
  }

  @Test func repairRebuildsDamagedCrossReferences() throws {
    let original = try PDFFixtures.onePage()
    let damaged = damagedFixture()
    #expect(throws: PDFError.self) {
      _ = try PDFParser.parse(damaged)
    }
    let repaired = PDFRepair.repair(damaged)
    let data = try #require(repaired.data)
    let graph = try #require(repaired.graph)
    #expect(repaired.report.actions.contains(.rebuiltCrossReference))
    #expect(repaired.report.wasRepaired)
    #expect(repaired.report.editSafe)
    // The repaired document parses, keeps its content, and validates.
    let reparsed = try PDFParser.parse(data)
    #expect(reparsed.pageIDs.count == 1)
    #expect(reparsed.graph.objects.count == graph.objects.count)
    try reparsed.graph.validate()
    // P38-021: the derivative is distinct from the damaged input, and the
    // pristine fixture still parses with the same page count.
    #expect(data != damaged)
    #expect(try PDFParser.parse(original).pageIDs.count == 1)
    #expect(!repaired.report.report().contains("gated"))
  }

  @Test func repairRecordsStreamLengthProvenance() throws {
    // A stream that declares the wrong /Length, with a corrupted xref.
    var graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    graph.objects[PDFObjectID(5)] = .stream(
      PDFStream(
        dictionary: [PDFName("Length"): .integer(3)],
        bytes: Data("BT /F1 12 Tf 72 700 Td (Hello) Tj ET\n".utf8)))
    // The writer normalizes /Length; the mismatch is patched into the bytes.
    var written = String(decoding: try PDFWriter.write(graph), as: UTF8.self)
    if let range = written.range(of: "/Length \\d+", options: .regularExpression) {
      written.replaceSubrange(range, with: "/Length 3")
    }
    let damaged = corruptCrossReference(Data(written.utf8))
    let repaired = PDFRepair.repair(damaged)
    #expect(repaired.data != nil)
    #expect(repaired.report.actions.contains(.recoveredStreamLength))
    #expect(repaired.report.notes.contains { $0.contains("actual bytes are authoritative") })
  }

  @Test func repairRefusesUnrepairableInput() throws {
    let junk = Data((0..<512).map { UInt8($0 % 251) })
    let repaired = PDFRepair.repair(junk)
    #expect(repaired.data == nil)
    #expect(!repaired.report.editSafe)
    #expect(repaired.report.notes.contains { $0.contains("not a repairable PDF") })
  }

  @Test func repairGatesEditsWhenSanityFails() throws {
    // A parseable but suspicious document (a sparse object index), with a
    // damaged xref. The parser accepts sparse numbering, the sanity check
    // flags it, and edits stay gated.
    let damaged = damagedFixture { text in
      text = text.replacingOccurrences(of: "5 0 obj", with: "50000 0 obj")
      text = text.replacingOccurrences(of: "5 0 R", with: "50000 0 R")
    }
    let repaired = PDFRepair.repair(damaged)
    #expect(repaired.data != nil)
    #expect(!repaired.report.editSafe)
    #expect(repaired.report.notes.contains { $0.contains("sparse") })
    #expect(repaired.report.report().contains("gated"))
    // P38-021: the derivative is written separately; the source is untouched.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-repair-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("source.pdf")
    let repairedURL = directory.appendingPathComponent("repaired.pdf")
    try damaged.write(to: sourceURL)
    try (repaired.data ?? Data()).write(to: repairedURL)
    #expect(try Data(contentsOf: sourceURL) == damaged)
    #expect(try Data(contentsOf: repairedURL) != damaged)
  }
}
