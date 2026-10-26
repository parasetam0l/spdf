import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// AUT-05/AUT-06 evidence artifact writer (opt-in):
///   SPDF_AUTOMATION_ARTIFACT_DIR=<dir> swift test --filter AutomationArtifactTests
/// Writes the CLI inputs, the expected semantic JSON and a deterministic
/// watched-folder report; the shell qualification runs the built spdf-automation
/// binary against these files and verifies exit codes and structured output.
@Suite("Automation artifacts")
struct AutomationArtifactTests {
  @Test func writesArtifactsWhenRequested() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let directoryPath = environment["SPDF_AUTOMATION_ARTIFACT_DIR"],
      !directoryPath.isEmpty
    else { return }
    let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    // Inputs.
    var graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 600, 272, 624], name: "Name"),
        AddTextFieldCommand(pageID: pageID, rect: [72, 560, 272, 584], name: "Email"),
        SetFormTextCommand(fieldName: "Name", text: "Asha Demir"),
        SetFormTextCommand(fieldName: "Email", text: "asha@example.com"),
      ]), to: graph)
    try PDFWriter.write(graph).write(
      to: directory.appendingPathComponent("automation-form.pdf"))
    try PDFWriter.write(PDFFixtures.graph(pages: 2)).write(
      to: directory.appendingPathComponent("automation-two-page.pdf"))

    // Values sidecar through the CLI itself (structured output).
    let valuesPath = directory.appendingPathComponent("automation-values.json")
    let exportResult = AutomationCLI.perform(
      arguments: [
        "forms-export", directory.appendingPathComponent("automation-form.pdf").path,
        "--output", valuesPath.path,
      ])
    #expect(exportResult.exitCode == 0)

    // Deterministic watched-folder report: one stable input processed once, one
    // failure visible, plus a pending file that is still settling.
    let work = directory.appendingPathComponent("watch-workspace", isDirectory: true)
    let watched = work.appendingPathComponent("watched", isDirectory: true)
    let output = work.appendingPathComponent("output", isDirectory: true)
    try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let stateURL = work.appendingPathComponent("state.json")
    let clock = Date(timeIntervalSince1970: 3_000_000)
    let stable = WatchedFileSnapshot(
      url: watched.appendingPathComponent("stable.pdf"), size: 11,
      modificationDate: Date(timeIntervalSince1970: 2_900_000))
    let failing = WatchedFileSnapshot(
      url: watched.appendingPathComponent("failing.pdf"), size: 22,
      modificationDate: Date(timeIntervalSince1970: 2_900_000))
    let settling = WatchedFileSnapshot(
      url: watched.appendingPathComponent("settling.pdf"), size: 33,
      modificationDate: Date(timeIntervalSince1970: 2_900_000))
    var now = clock
    var processed = 0
    var settlingChanged = false
    let settlingUpdated = WatchedFileSnapshot(
      url: settling.url, size: 44,
      modificationDate: Date(timeIntervalSince1970: 2_950_000))
    let providers = WatchedFolderEngine.Providers(
      listFiles: { _ in
        [stable, failing, settlingChanged ? settlingUpdated : settling]
      },
      now: { now },
      execute: { input, _, _ in
        if input.lastPathComponent == "failing.pdf" {
          throw AutomationWatchError.executionFailed("Simulated unreadable input")
        }
        processed += 1
        return output.appendingPathComponent("stable-processed.pdf")
      })
    let configuration = try WatchedFolderConfiguration(
      name: "Evidence watch", watchedFolders: [watched], outputFolder: output,
      recipe: AutomationRecipe(
        name: "Export pages", steps: [
          AutomationRecipeStep(operation: "export-pages", options: ["--pages": "1"])
        ]),
      settleInterval: 2)
    let engine = WatchedFolderEngine(
      configuration: configuration, stateURL: stateURL, providers: providers)
    _ = try engine.scanOnce()
    // Move inside the settle window once, then settle only the stable/failing
    // inputs by rendering a second scan where settling.pdf changes.
    now = clock.addingTimeInterval(3)
    settlingChanged = true
    let report = try engine.scanOnce()
    #expect(processed == 1)
    #expect(report.processed.count == 1)
    #expect(report.failed.count == 1)
    #expect(report.pendingCount == 1)
    try report.jsonData()?.write(
      to: directory.appendingPathComponent("automation-watch-report.json"))
    let stateData = try Data(contentsOf: stateURL)
    try stateData.write(to: directory.appendingPathComponent("automation-watch-state.json"))

    // Expected semantics for the shell verification.
    var expectedValues: [String: Any] = [:]
    if let data = try? Data(contentsOf: valuesPath),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let fields = object["fields"] as? [[String: Any]]
    {
      for field in fields {
        if let name = field["name"] as? String, let value = field["value"] as? String {
          expectedValues[name] = value
        }
      }
    }
    let expected: [String: Any] = [
      "profile": AutomationProfile.identifier,
      "schemaVersion": AutomationProfile.schemaVersion,
      "operations": AutomationProfile.operations.map(\.name),
      "exitCodes": AutomationProfile.exitCodes.map { ["code": Int($0.code), "name": $0.name] },
      "restrictions": AutomationProfile.restrictions,
      "formValues": expectedValues,
      "twoPageCount": 2,
      "watchSummary": report.summary,
      "watchProcessed": report.processed.map(\.path),
      "watchFailed": report.failed.map(\.path),
    ]
    try JSONSerialization.data(
      withJSONObject: expected, options: [.prettyPrinted, .sortedKeys]
    ).write(to: directory.appendingPathComponent("automation-expected.json"))

    #expect(AutomationProfile.operations.count == 9)
    #expect(AutomationProfile.restrictions.count >= 8)
  }
}
