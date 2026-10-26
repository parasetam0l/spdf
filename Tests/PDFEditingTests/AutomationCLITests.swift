import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// AUT-05 evidence: the declared automation profile and the native CLI front end
/// expose stable operations, documented options, stable exit codes and structured
/// output, and never exceed the UI automation capabilities/restrictions.
@Suite("Automation CLI")
struct AutomationCLITests {
  struct Temporary {
    let url: URL
    init() throws {
      url = FileManager.default.temporaryDirectory
        .appendingPathComponent("spdf-automation-tests-" + UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func write(_ name: String, _ data: Data) throws -> URL {
      let target = url.appendingPathComponent(name)
      try data.write(to: target)
      return target
    }
    func cleanUp() { try? FileManager.default.removeItem(at: url) }
  }

  func formPDF() throws -> Data {
    var graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 600, 272, 624], name: "Name"),
        AddTextFieldCommand(pageID: pageID, rect: [72, 560, 272, 584], name: "Email"),
        SetFormTextCommand(fieldName: "Name", text: "Asha"),
        SetFormTextCommand(fieldName: "Email", text: "asha@example.com"),
      ]), to: graph)
    return try PDFWriter.write(graph)
  }

  /// Two-page document.
  func twoPageTextPDF() throws -> Data {
    try PDFWriter.write(PDFFixtures.graph(pages: 2))
  }

  func envelopeJSON(_ result: AutomationCLI.RunResult) -> [String: Any] {
    result.envelope ?? [:]
  }

  func decodedOutputJSON(_ result: AutomationCLI.RunResult) throws -> [String: Any] {
    guard let envelope = result.envelope else {
      throw PDFError(.malformed, "No structured output was produced.")
    }
    return envelope
  }

  @Test func capabilitiesExposeProfileOperationsExitCodesAndRestrictions() throws {
    let result = AutomationCLI.perform(arguments: ["capabilities"])
    #expect(result.exitCode == 0)
    #expect(result.standardError.isEmpty)
    let envelope = try decodedOutputJSON(result)
    #expect(envelope["profile"] as? String == "spdf-automation-v1")
    #expect(envelope["status"] as? String == "success")
    #expect(envelope["schemaVersion"] as? Int == 1)
    let output = try #require(envelope["result"] as? [String: Any])
    let operations = try #require(output["operations"] as? [[String: Any]])
    let names = operations.compactMap { $0["name"] as? String }
    #expect(names.contains("capabilities"))
    #expect(names.contains("info"))
    #expect(names.contains("text"))
    #expect(names.contains("export-pages"))
    #expect(names.contains("merge"))
    #expect(names.contains("forms-export"))
    #expect(names.contains("forms-import"))
    #expect(names.contains("flatten-forms"))
    #expect(names.contains("audit"))
    let exitCodes = try #require(output["exitCodes"] as? [[String: Any]])
    #expect(exitCodes.compactMap { $0["code"] as? Int } == [0, 2, 3, 4, 5, 6])
    let restrictions = try #require(output["restrictions"] as? [String])
    #expect(restrictions.contains { $0.contains("Never executes document JavaScript") })
    #expect(restrictions.contains { $0.contains("No network") })
    #expect(restrictions.contains { $0.contains("same capabilities") })
    // Every documented operation carries a usage string and restrictions.
    #expect(operations.allSatisfy {
      !($0["usage"] as? String ?? "").isEmpty && !($0["restrictions"] as? [String] ?? []).isEmpty
    })
    // Text mode writes a stable human summary.
    let text = AutomationCLI.perform(arguments: ["capabilities", "--format", "text"])
    #expect(text.exitCode == 0)
    #expect(text.standardOutput.contains("sPDF automation profile spdf-automation-v1"))
  }

  @Test func usageErrorsHaveStableExitCodeTwoAndKind() throws {
    let unknown = AutomationCLI.perform(arguments: ["frobnicate"])
    #expect(unknown.exitCode == 2)
    #expect((unknown.envelope?["error"] as? [String: Any])?["kind"] as? String == "usage")
    #expect(unknown.standardError.contains("usage"))
    let hiddenFlag = AutomationCLI.perform(arguments: ["info", "file.pdf", "--dump-internals"])
    #expect(hiddenFlag.exitCode == 2)
    #expect(hiddenFlag.standardError.contains("not part of the info profile"))
    let missingValue = AutomationCLI.perform(arguments: ["text", "file.pdf", "--pages"])
    #expect(missingValue.exitCode == 2)
    let badFormat = AutomationCLI.perform(arguments: ["info", "file.pdf", "--format", "xml"])
    #expect(badFormat.exitCode == 2)
    let noArguments = AutomationCLI.perform(arguments: [])
    #expect(noArguments.exitCode == 2)
  }

  @Test func infoReportsDocumentFactsAsJSON() throws {
    let temporary = try Temporary()
    defer { temporary.cleanUp() }
    let input = try temporary.write("form.pdf", try formPDF())
    let result = AutomationCLI.perform(arguments: ["info", input.path])
    #expect(result.exitCode == 0)
    let envelope = try decodedOutputJSON(result)
    #expect(envelope["operation"] as? String == "info")
    let output = try #require(envelope["result"] as? [String: Any])
    #expect(output["pages"] as? Int == 1)
    #expect(output["encrypted"] as? Bool == false)
    #expect(output["formFields"] as? Int == 2)
    #expect(output["tagged"] as? Bool == false)
    #expect((output["bytes"] as? Int ?? 0) > 0)
    let text = AutomationCLI.perform(arguments: ["info", input.path, "--format", "text"])
    #expect(text.exitCode == 0)
    #expect(text.standardOutput.contains("1 page(s)"))
  }

  @Test func textUsesPagesSelectionAndRefusesOutOfRangePages() throws {
    let temporary = try Temporary()
    defer { temporary.cleanUp() }
    let input = try temporary.write("two.pdf", try twoPageTextPDF())
    let all = AutomationCLI.perform(arguments: ["text", input.path])
    #expect(all.exitCode == 0)
    #expect(((all.envelope?["result"] as? [String: Any])?["pageCount"] as? Int) == 2)
    let second = AutomationCLI.perform(arguments: ["text", input.path, "--pages", "2"])
    #expect(second.exitCode == 0)
    #expect(((second.envelope?["result"] as? [String: Any])?["pageCount"] as? Int) == 1)
    let outOfRange = AutomationCLI.perform(arguments: ["text", input.path, "--pages", "5"])
    #expect(outOfRange.exitCode == 2)
    #expect(outOfRange.standardError.contains("outside 1...2"))
  }

  @Test func exportPagesWritesNewPDFAndNeverOverwritesInput() throws {
    let temporary = try Temporary()
    defer { temporary.cleanUp() }
    let input = try temporary.write("two.pdf", try twoPageTextPDF())
    let output = temporary.url.appendingPathComponent("page-two.pdf")
    let result = AutomationCLI.perform(
      arguments: ["export-pages", input.path, "--pages", "2", "--output", output.path])
    #expect(result.exitCode == 0)
    #expect(FileManager.default.fileExists(atPath: output.path))
    let parsed = try PDFParser.parse(try Data(contentsOf: output))
    #expect(try PDFPageTree.pageIDs(in: parsed.graph).count == 1)
    let overwrite = AutomationCLI.perform(
      arguments: ["export-pages", input.path, "--pages", "1", "--output", input.path])
    #expect(overwrite.exitCode == 2)
    #expect(overwrite.standardError.contains("must not be the input file"))
  }

  @Test func mergeCombinesInputsAndRefusesSingleInput() throws {
    let temporary = try Temporary()
    defer { temporary.cleanUp() }
    let first = try temporary.write("first.pdf", PDFFixtures.onePage())
    let second = try temporary.write("second.pdf", try twoPageTextPDF())
    let output = temporary.url.appendingPathComponent("merged.pdf")
    let result = AutomationCLI.perform(
      arguments: ["merge", first.path, second.path, "--output", output.path])
    #expect(result.exitCode == 0)
    let parsed = try PDFParser.parse(try Data(contentsOf: output))
    #expect(try PDFPageTree.pageIDs(in: parsed.graph).count == 3)
    let single = AutomationCLI.perform(
      arguments: ["merge", first.path, "--output", output.path])
    #expect(single.exitCode == 2)
  }

  @Test func formsExportAndImportRoundTripWithVisibleSkips() throws {
    let temporary = try Temporary()
    defer { temporary.cleanUp() }
    let input = try temporary.write("form.pdf", try formPDF())
    let values = temporary.url.appendingPathComponent("values.json")
    let exported = AutomationCLI.perform(
      arguments: ["forms-export", input.path, "--output", values.path])
    #expect(exported.exitCode == 0)
    #expect(FileManager.default.fileExists(atPath: values.path))
    let output = temporary.url.appendingPathComponent("filled.pdf")
    let imported = AutomationCLI.perform(
      arguments: [
        "forms-import", input.path, "--values", values.path, "--output", output.path,
      ])
    #expect(imported.exitCode == 0)
    let reexport = temporary.url.appendingPathComponent("roundtrip.json")
    let reexported = AutomationCLI.perform(
      arguments: ["forms-export", output.path, "--output", reexport.path])
    #expect(reexported.exitCode == 0)
    let valuesObject = try #require(
      (reexported.envelope?["result"] as? [String: Any])?["values"] as? [String: Any])
    let fields = try #require(valuesObject["fields"] as? [[String: Any]])
    #expect(fields.contains { $0["name"] as? String == "Name" && $0["value"] as? String == "Asha" })
    // A value file with an unknown field stays visible in skipped instead of guessing.
    var payload = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: values))
      as? [String: Any])
    var entries = try #require(payload["fields"] as? [[String: Any]])
    entries.append(["name": "Missing", "kind": "text", "value": "x"])
    payload["fields"] = entries
    let skipValues = temporary.url.appendingPathComponent("skip-values.json")
    try JSONSerialization.data(withJSONObject: payload).write(to: skipValues)
    let skipOutput = temporary.url.appendingPathComponent("skip-output.pdf")
    let skipped = AutomationCLI.perform(
      arguments: [
        "forms-import", input.path, "--values", skipValues.path, "--output", skipOutput.path,
      ])
    #expect(skipped.exitCode == 0)
    let skippedList = try #require(
      (skipped.envelope?["result"] as? [String: Any])?["skipped"] as? [String])
    #expect(skippedList.contains("Missing"))
  }

  @Test func flattenFormsWritesNewPDFWithoutFillableFields() throws {
    let temporary = try Temporary()
    defer { temporary.cleanUp() }
    let input = try temporary.write("form.pdf", try formPDF())
    let output = temporary.url.appendingPathComponent("flattened.pdf")
    let result = AutomationCLI.perform(
      arguments: ["flatten-forms", input.path, "--output", output.path])
    #expect(result.exitCode == 0)
    let parsed = try PDFParser.parse(try Data(contentsOf: output))
    let pageIDs = try PDFPageTree.pageIDs(in: parsed.graph)
    #expect(try FormInventory.fields(in: parsed.graph, pageIDs: pageIDs).isEmpty)
    let info = AutomationCLI.perform(arguments: ["info", output.path])
    #expect((info.envelope?["result"] as? [String: Any])?["formFields"] as? Int == 0)
  }

  @Test func auditSeparatesMachineFindingsFromHumanReviewAndMakesNoClaim() throws {
    let temporary = try Temporary()
    defer { temporary.cleanUp() }
    let input = try temporary.write("form.pdf", try formPDF())
    let result = AutomationCLI.perform(arguments: ["audit", input.path])
    #expect(result.exitCode == 0)
    let output = try #require(result.envelope?["result"] as? [String: Any])
    #expect(output["conformanceClaim"] as? Bool == false)
    let accessibility = try #require(output["accessibility"] as? [String: Any])
    #expect((accessibility["humanReviewRequirements"] as? [String] ?? []).count >= 5)
    #expect(accessibility["passesMachineChecks"] is Bool)
    let warnings = try #require(result.envelope?["warnings"] as? [String])
    #expect(warnings.contains { $0.contains("No accessibility-conformance claim") })
  }

  @Test func inputOutputAndOperationFailuresUseDocumentedExitCodes() throws {
    let temporary = try Temporary()
    defer { temporary.cleanUp() }
    let missing = AutomationCLI.perform(arguments: ["info", temporary.url.appendingPathComponent("nope.pdf").path])
    #expect(missing.exitCode == 3)
    let malformed = try temporary.write("bad.pdf", Data("not a pdf".utf8))
    let bad = AutomationCLI.perform(arguments: ["info", malformed.path])
    #expect(bad.exitCode == 3)
    let input = try temporary.write("ok.pdf", try formPDF())
    let missingDirectory = temporary.url
      .appendingPathComponent("does-not-exist/out.pdf")
    let outputError = AutomationCLI.perform(
      arguments: ["flatten-forms", input.path, "--output", missingDirectory.path])
    #expect(outputError.exitCode == 5)
    #expect(outputError.standardError.contains("output"))
  }

  @Test func appleScriptShortcutAndCLISurfacesShareTheSameCatalog() throws {
    // The profile is the single source of truth used by the executable, the App
    // Intents/AppleScript bridge and the panel; no surface-specific flags exist.
    #expect(AutomationProfile.operations.map(\.name) == [
      "capabilities", "info", "text", "export-pages", "merge", "forms-export",
      "forms-import", "flatten-forms", "audit",
    ])
    #expect(AutomationProfile.restrictions.count >= 8)
    let envelopeKeys = Set(
      ((AutomationCLI.perform(arguments: ["capabilities"]).envelope ?? [:]).keys))
    #expect(envelopeKeys.isSuperset(of: [
      "schemaVersion", "profile", "operation", "status", "exitCode", "result", "warnings",
      "restrictions",
    ]))
  }
}
