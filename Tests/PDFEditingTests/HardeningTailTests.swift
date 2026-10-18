import Foundation
import PDFCore
import PDFFixtures
@testable import PDFEditing
import Testing

/// P38-023–P38-030: minimization, differential comparison, preservation,
/// failure-path safety, gate verification, and coverage records.
@Suite("Hardening tails")
struct HardeningTailTests {
  private func fixture(_ relative: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures")
      .appendingPathComponent(relative)
    return try Data(contentsOf: url)
  }

  // MARK: - P38-023

  @Test func failingInputsMinimizeIntoSmallFixtures() throws {
    let damaged = try fixture("Malformed/bad-startxref.pdf")
    let originalKind: PDFError.Kind? = {
      do {
        _ = try PDFParser.parse(damaged)
        return nil
      } catch let error as PDFError {
        return error.kind
      } catch {
        return nil
      }
    }()
    // The failure predicate keeps the *same* failure class and structural
    // content, so the minimized input stays meaningful rather than 1 byte.
    let result = FuzzMinimizer.minimize(damaged) { candidate in
      guard candidate.range(of: Data("obj".utf8)) != nil else { return false }
      do {
        _ = try PDFParser.parse(candidate)
        return false
      } catch let error as PDFError {
        return error.kind == originalKind
      } catch {
        return false
      }
    }
    #expect(result.data.count < damaged.count)
    #expect(result.data.range(of: Data("obj".utf8)) != nil)
    #expect(result.attempts > 0)
    print("[P38-023] \(result.summary)")

    // The committed minimized fixtures still fail explicitly and are bounded.
    for name in ["truncated.pdf", "bad-startxref.pdf", "cyclic-structure.pdf"] {
      let data = try fixture("Malformed/\(name)")
      #expect(data.count < 8 * 1_024 * 1_024)
      do {
        let parsed = try PDFParser.parse(data)
        // The cyclic-structure fixture parses; its structure tree must be
        // bounded and report the cycle rather than recursing.
        let inventory = try PDFStructureInspector.inspect(in: parsed.graph, pageIDs: parsed.pageIDs)
        #expect(inventory.issues.contains { $0.kind == .cyclicReference })
      } catch let error as PDFError {
        #expect([.malformed, .unsupported, .limitExceeded].contains(error.kind))
      }
    }
  }

  // MARK: - P38-024

  @Test func differentialParsingAgreesWithIndependentTools() throws {
    let tools = ["/opt/homebrew/bin/qpdf", "/opt/homebrew/bin/mutool"]
    guard tools.allSatisfy({ FileManager.default.isExecutableFile(atPath: $0) }) else { return }
    func run(_ tool: String, _ arguments: [String]) -> String? {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: tool)
      process.arguments = arguments
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = Pipe()
      do { try process.run() } catch { return nil }
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return nil }
      return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
    for name in ["one-page.pdf", "text-edit.pdf", "tagged-pages.pdf"] {
      let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)")
      let data = try Data(contentsOf: url)
      let ours = try PDFParser.parse(data)
      let qpdfPages = run("/opt/homebrew/bin/qpdf", ["--show-npages", url.path])?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      #expect(qpdfPages == String(ours.pageIDs.count), "\(name): qpdf disagrees")
      let mutoolPages = run("/opt/homebrew/bin/mutool", ["info", url.path])?
        .split(separator: "\n").first { $0.contains("Pages") }
      #expect(mutoolPages?.contains(String(ours.pageIDs.count)) == true, "\(name): mutool disagrees")
      #expect(run("/opt/homebrew/bin/qpdf", ["--check", url.path]) != nil, "\(name): qpdf --check failed")
    }
  }

  // MARK: - P38-026

  @Test func unsupportedObjectsSurviveUnrelatedEdits() throws {
    var graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    // JPX image, unknown-filter stream, Separation image, embedded file.
    graph.objects[PDFObjectID(800)] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Image")),
          PDFName("Width"): .integer(4), PDFName("Height"): .integer(4),
          PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
          PDFName("BitsPerComponent"): .integer(8),
          PDFName("Filter"): .name(PDFName("JPXDecode")),
        ], bytes: Data([0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A])))
    graph.objects[PDFObjectID(801)] = .stream(
      PDFStream(
        dictionary: [PDFName("Filter"): .name(PDFName("JBIG2Decode"))],
        bytes: Data(repeating: 0xAB, count: 64)))
    graph.objects[PDFObjectID(802)] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Image")),
          PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
          PDFName("ColorSpace"): .array([
            .name(PDFName("Separation")), .name(PDFName("Pantone")),
            .name(PDFName("DeviceCMYK")), .reference(PDFObjectID(803)),
          ]),
          PDFName("BitsPerComponent"): .integer(8),
        ], bytes: Data(repeating: 0x11, count: 4)))
    graph.objects[PDFObjectID(803)] = .stream(PDFStream(bytes: Data([0, 0, 0, 0])))
    graph.objects[PDFObjectID(804)] = .dictionary([
      PDFName("Type"): .name(PDFName("Filespec")),
      PDFName("F"): .string(Data("note.txt".utf8)),
      PDFName("EF"): .dictionary([PDFName("F"): .reference(PDFObjectID(805))]),
    ])
    graph.objects[PDFObjectID(805)] = .stream(PDFStream(bytes: Data("payload".utf8)))
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let before = graph
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([RotatePagesCommand(pageIDs: [pageID], byDegrees: 90)]), to: graph)
    for id in [800, 801, 802, 803, 804, 805] {
      #expect(edited.objects[PDFObjectID(id)] == before.objects[PDFObjectID(id)], "object \(id)")
    }
    // And a full rewrite keeps them byte-equivalent too.
    let written = try PDFWriter.write(edited)
    let reparsed = try PDFParser.parse(written)
    guard case .stream(let originalImage)? = before.objects[PDFObjectID(800)],
      case .stream(let rewrittenImage)? = reparsed.graph.objects[PDFObjectID(800)]
    else {
      Issue.record("JPX image missing after rewrite")
      return
    }
    #expect(rewrittenImage.bytes == originalImage.bytes)
    #expect(rewrittenImage.dictionary[PDFName("Filter")] == originalImage.dictionary[PDFName("Filter")])
    #expect(
      rewrittenImage.dictionary[PDFName("ColorSpace")] == originalImage.dictionary[PDFName("ColorSpace")])
    #expect(reparsed.graph.objects[PDFObjectID(804)] == before.objects[PDFObjectID(804)])
    guard case .stream(let originalUnknown)? = before.objects[PDFObjectID(801)],
      case .stream(let rewrittenUnknown)? = reparsed.graph.objects[PDFObjectID(801)]
    else {
      Issue.record("unknown-filter stream missing after rewrite")
      return
    }
    #expect(rewrittenUnknown.bytes == originalUnknown.bytes)
    #expect(rewrittenUnknown.dictionary[PDFName("Filter")] == originalUnknown.dictionary[PDFName("Filter")])
  }

  // MARK: - P38-027

  @Test func failurePathsNeverReplaceValidOriginals() throws {
    // An unparseable source is never written: parsing fails explicitly and the
    // repair path returns either nothing or a distinct derivative.
    let malformed = try fixture("Malformed/truncated.pdf")
    #expect(throws: PDFError.self) { _ = try PDFParser.parse(malformed) }
    let before = malformed
    let repaired = PDFRepair.repair(malformed)
    #expect(malformed == before)
    if let data = repaired.data {
      #expect(data != malformed)
      #expect((try? PDFParser.parse(data)) != nil)
    }
  }

  // MARK: - P38-028

  @Test func redactionAndSignatureGatesHold() throws {
    // A signed document refuses rewriting/optimization by policy.
    let signed = try PDFParser.parse(try fixture("Signed/signed-one-page.pdf"))
    #expect(throws: PDFError.self) { _ = try PDFWriter.write(signed.graph) }
    #expect(throws: PDFError.self) { _ = try PDFOptimizer.lossless(signed.graph) }
    // A redacted derivative contains no removed text after reopening (the
    // same fixture the redaction suite uses).
    let graph = try PDFParser.parse(PDFFixtures.textWidthsPages()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let text = try PageTextLayout.build(pageID: pageID, in: graph).clusters.map(\.text).joined()
    #expect(!text.isEmpty)
    let redacted = try PDFEditingEngine.commit(
      PDFTransaction([
        RedactRegionsCommand(pageID: pageID, regions: [[40, 705, 95, 735]])
      ]), to: graph)
    let after = try PageTextLayout.build(pageID: pageID, in: redacted).clusters.map(\.text).joined()
    #expect(after.count < text.count)
    let written = try PDFWriter.write(redacted)
    let reopened = try PDFParser.parse(written)
    let reopenedText = try PageTextLayout.build(pageID: pageID, in: reopened.graph)
      .clusters.map(\.text).joined()
    #expect(reopenedText.count == after.count)
  }

  @Test func objectStreamExtensionToContentStreamRefusesAsMalformed() throws {
    do {
      _ = try PDFParser.parse(PDFFixtures.chainedObjectStreamPages())
      Issue.record("Invalid object-stream extension parsed without refusal")
    } catch let error as PDFError {
      #expect(error.kind == .malformed)
      #expect(error.message.contains("Extends"))
    }
  }

  @Test func validObjectStreamCollectionResolvesAndRewrites() throws {
    let parsed = try PDFParser.parse(PDFFixtures.chainedObjectStreamPages(validCollection: true))
    #expect(parsed.pageCount == 1)
    let text = try PageTextLayout.build(pageID: parsed.pageIDs[0], in: parsed.graph).clusters.map(\.text).joined()
    #expect(text.contains("chained-stream fixture"))
    #expect(try PDFParser.parse(PDFWriter.write(parsed.graph)).graph == parsed.graph)
  }

  // MARK: - P38-029/P38-030

  @Test func hardeningCoverageRecordIsComplete() throws {
    // The coverage record lists every fuzz family with its seed and budget.
    let coverage = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Docs/Hardening.md"),
      encoding: .utf8)
    for family in [
      "lexical", "nesting", "cross-reference", "object streams", "streams", "content",
      "fonts", "images", "annotations", "tags", "encryption", "signatures",
    ] {
      #expect(coverage.contains(family), "coverage lacks \(family)")
    }
    #expect(coverage.contains("representative documents"))
    #expect(coverage.lowercased().contains("release corpus gate"))
  }
}

/// P06-023: the repair header scan is bounded — tiny budgets report the
/// truncation instead of silently half-rebuilding.
extension HardeningTailTests {
  @Test func repairScanBudgetBoundsTriage() throws {
    let damaged = try fixture("Malformed/bad-startxref.pdf")
    // A normal budget repairs or refuses on the merits, with no scan note
    // when the whole file fits the budget.
    let full = PDFRepair.repair(damaged)
    #expect(!full.report.notes.contains { $0.contains("scan budget") })
    // A 16-byte scan budget finds no headers and says exactly why.
    var tiny = HardeningBudget.untrusted
    tiny.scanBytes = 16
    let starved = PDFRepair.repair(damaged, budget: tiny)
    #expect(starved.data == nil)
    #expect(starved.report.notes.contains { $0.contains("scan budget") })
  }
}

/// P04-017: repair warnings carry object identity and byte spans without
/// document content.
extension HardeningTailTests {
  @Test func repairDiagnosticsCarrySpans() throws {
    let damaged = try fixture("Malformed/truncated.pdf")
    let report = PDFRepair.repair(damaged).report
    for diagnostic in report.diagnostics {
      #expect(diagnostic.operation == "repair")
      #expect(diagnostic.severity == .warning)
    }
    // The truncated fixture's rebuilt stream lengths (if any) name their
    // objects and spans; content never appears in diagnostics.
    for diagnostic in report.diagnostics where diagnostic.object != nil {
      let span = try #require(diagnostic.span)
      #expect(span.start >= 0 && span.end >= span.start)
    }
  }
}
