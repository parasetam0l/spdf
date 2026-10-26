import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// AUT-06 evidence: explicit watched folders and recipes, atomic arrival
/// detection, exactly-once processing per stable input, loop prevention and
/// visible failures.
@Suite("Watched folder automation")
struct WatchedFolderAutomationTests {
  struct Workspace {
    let root: URL
    let watched: URL
    let output: URL
    let stateURL: URL
    init() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("spdf-watch-tests-" + UUID().uuidString, isDirectory: true)
      watched = root.appendingPathComponent("watched", isDirectory: true)
      output = root.appendingPathComponent("output", isDirectory: true)
      try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      stateURL = root.appendingPathComponent("state/state.json")
    }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
  }

  final class Clock {
    var now: Date
    init(_ now: Date) { self.now = now }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
  }

  func configuration(
    _ workspace: Workspace, settle: TimeInterval = 1,
    steps: [AutomationRecipeStep] = [AutomationRecipeStep(operation: "flatten-forms")]
  ) throws -> WatchedFolderConfiguration {
    try WatchedFolderConfiguration(
      name: "Test watch", watchedFolders: [workspace.watched],
      outputFolder: workspace.output,
      recipe: AutomationRecipe(name: "Test recipe", steps: steps), settleInterval: settle)
  }

  func snapshot(
    _ workspace: Workspace, name: String = "incoming.pdf", size: Int64 = 10,
    modified: Date = Date(timeIntervalSince1970: 1_000_000)
  ) -> WatchedFileSnapshot {
    WatchedFileSnapshot(
      url: workspace.watched.appendingPathComponent(name), size: size,
      modificationDate: modified)
  }

  @Test func configurationRequiresExplicitFoldersAndASeparateOutputFolder() throws {
    let workspace = try Workspace()
    defer { workspace.cleanUp() }
    let recipe = AutomationRecipe(
      name: "Flatten", steps: [AutomationRecipeStep(operation: "flatten-forms")])
    #expect(throws: AutomationWatchError.self) {
      _ = try WatchedFolderConfiguration(
        name: "No folders", watchedFolders: [], outputFolder: workspace.output, recipe: recipe)
    }
    #expect(throws: AutomationWatchError.self) {
      _ = try WatchedFolderConfiguration(
        name: "Nested output", watchedFolders: [workspace.root],
        outputFolder: workspace.watched.appendingPathComponent("out"), recipe: recipe)
    }
    #expect(throws: AutomationWatchError.self) {
      _ = try WatchedFolderConfiguration(
        name: "Bad interval", watchedFolders: [workspace.watched],
        outputFolder: workspace.output, recipe: recipe, settleInterval: 0)
    }
    #expect(throws: AutomationWatchError.self) {
      _ = try WatchedFolderConfiguration(
        name: "Read op", watchedFolders: [workspace.watched], outputFolder: workspace.output,
        recipe: AutomationRecipe(name: "Info", steps: [
          AutomationRecipeStep(operation: "info")
        ]))
    }
    #expect(throws: AutomationWatchError.self) {
      _ = try WatchedFolderConfiguration(
        name: "Unknown op", watchedFolders: [workspace.watched],
        outputFolder: workspace.output,
        recipe: AutomationRecipe(name: "Unknown", steps: [
          AutomationRecipeStep(operation: "sign")
        ]))
    }
    #expect(throws: AutomationWatchError.self) {
      _ = try WatchedFolderConfiguration(
        name: "Engine-owned option", watchedFolders: [workspace.watched],
        outputFolder: workspace.output,
        recipe: AutomationRecipe(name: "Output option", steps: [
          AutomationRecipeStep(operation: "flatten-forms", options: ["--output": "/tmp/x.pdf"])
        ]))
    }
  }

  @Test func atomicArrivalWaitsForAStableSampleAndProcessesOnlyOnce() throws {
    let workspace = try Workspace()
    defer { workspace.cleanUp() }
    let clock = Clock(Date(timeIntervalSince1970: 2_000_000))
    let file = snapshot(workspace)
    var executions: [String] = []
    let providers = WatchedFolderEngine.Providers(
      listFiles: { _ in [file] },
      now: { clock.now },
      execute: { input, _, _ in
        executions.append(input.lastPathComponent)
        return workspace.output.appendingPathComponent("done.pdf")
      })
    let engine = WatchedFolderEngine(
      configuration: try configuration(workspace, settle: 1), stateURL: workspace.stateURL,
      providers: providers)
    let first = try engine.scanOnce()
    #expect(first.pendingCount == 1)
    #expect(first.processed.isEmpty)
    #expect(executions.isEmpty)
    // Still inside the settle interval.
    clock.advance(0.5)
    let second = try engine.scanOnce()
    #expect(second.pendingCount == 1)
    #expect(executions.isEmpty)
    // Settled and unchanged: processed exactly once.
    clock.advance(1.0)
    let third = try engine.scanOnce()
    #expect(third.processed.count == 1)
    #expect(third.processed.first?.output?.hasSuffix("done.pdf") == true)
    #expect(executions.count == 1)
    clock.advance(10)
    let fourth = try engine.scanOnce()
    #expect(fourth.processed.isEmpty)
    #expect(fourth.alreadyProcessedCount == 1)
    #expect(executions.count == 1)
    #expect(fourth.failed.isEmpty)
  }

  @Test func changedFileRestartsTheSettleWindow() throws {
    let workspace = try Workspace()
    defer { workspace.cleanUp() }
    let clock = Clock(Date(timeIntervalSince1970: 2_000_000))
    var current = snapshot(workspace, size: 10)
    var executions = 0
    let providers = WatchedFolderEngine.Providers(
      listFiles: { _ in [current] },
      now: { clock.now },
      execute: { _, _, _ in
        executions += 1
        return workspace.output.appendingPathComponent("done.pdf")
      })
    let engine = WatchedFolderEngine(
      configuration: try configuration(workspace, settle: 2), stateURL: workspace.stateURL,
      providers: providers)
    _ = try engine.scanOnce()
    clock.advance(1)
    #expect(try engine.scanOnce().pendingCount == 1)
    // The writer is still appending: new size resets the window.
    current = snapshot(workspace, size: 20)
    clock.advance(0.5)
    #expect(try engine.scanOnce().pendingCount == 1)
    #expect(executions == 0)
    clock.advance(2)
    let processed = try engine.scanOnce()
    #expect(processed.processed.count == 1)
    #expect(executions == 1)
  }

  @Test func stateSurvivesRestartAndKeepsExactlyOnceProcessing() throws {
    let workspace = try Workspace()
    defer { workspace.cleanUp() }
    let clock = Clock(Date(timeIntervalSince1970: 2_000_000))
    let file = snapshot(workspace)
    var executions = 0
    func makeEngine() throws -> WatchedFolderEngine {
      WatchedFolderEngine(
        configuration: try configuration(workspace, settle: 1),
        stateURL: workspace.stateURL,
        providers: WatchedFolderEngine.Providers(
          listFiles: { _ in [file] },
          now: { clock.now },
          execute: { _, _, _ in
            executions += 1
            return workspace.output.appendingPathComponent("done.pdf")
          }))
    }
    let firstEngine = try makeEngine()
    _ = try firstEngine.scanOnce()
    clock.advance(2)
    #expect(try firstEngine.scanOnce().processed.count == 1)
    #expect(executions == 1)
    // A relaunch loads the persisted state and does not process the file again.
    let secondEngine = try makeEngine()
    let afterRestart = try secondEngine.scanOnce()
    #expect(afterRestart.processed.isEmpty)
    #expect(afterRestart.alreadyProcessedCount == 1)
    #expect(executions == 1)
    let state = try secondEngine.loadState()
    #expect(state.inputs.values.contains { $0.status == .processed })
  }

  @Test func failuresStayVisibleAndCanBeRetriedExplicitly() throws {
    let workspace = try Workspace()
    defer { workspace.cleanUp() }
    let clock = Clock(Date(timeIntervalSince1970: 2_000_000))
    let file = snapshot(workspace)
    var shouldFail = true
    var executions = 0
    let providers = WatchedFolderEngine.Providers(
      listFiles: { _ in [file] },
      now: { clock.now },
      execute: { _, _, _ in
        executions += 1
        if shouldFail {
          throw AutomationWatchError.executionFailed("Simulated reader failure")
        }
        return workspace.output.appendingPathComponent("done.pdf")
      })
    let engine = WatchedFolderEngine(
      configuration: try configuration(workspace, settle: 1), stateURL: workspace.stateURL,
      providers: providers)
    _ = try engine.scanOnce()
    clock.advance(2)
    let failed = try engine.scanOnce()
    #expect(failed.failed.count == 1)
    #expect(failed.failed.first?.message.contains("Simulated reader failure") == true)
    #expect(failed.summary.contains("failed"))
    let state = try engine.loadState()
    #expect(state.inputs.values.contains { $0.status == .failed && $0.error != nil })
    // Without an explicit retry the failure is not retried or hidden.
    clock.advance(5)
    let noRetry = try engine.scanOnce()
    #expect(noRetry.processed.isEmpty)
    #expect(executions == 1)
    // After the cause is fixed the user can retry; the input is then processed once.
    shouldFail = false
    let retried = try engine.scanOnce(retryFailed: true)
    #expect(retried.processed.isEmpty || retried.pendingCount == 1)
    clock.advance(2)
    let settled = try engine.scanOnce()
    #expect(settled.processed.count == 1)
    #expect(executions == 2)
    #expect(settled.failed.isEmpty)
  }

  @Test func hiddenFilesOtherExtensionsAndRecordedOutputsAreSkipped() throws {
    let workspace = try Workspace()
    defer { workspace.cleanUp() }
    let clock = Clock(Date(timeIntervalSince1970: 2_000_000))
    let outputFile = workspace.watched.appendingPathComponent("previous-output.pdf")
    var executions = 0
    let files = [
      snapshot(workspace, name: ".hidden.pdf"),
      snapshot(workspace, name: "notes.txt"),
      snapshot(workspace, name: "incoming.pdf"),
      WatchedFileSnapshot(
        url: outputFile, size: 5, modificationDate: Date(timeIntervalSince1970: 999_999)),
    ]
    let providers = WatchedFolderEngine.Providers(
      listFiles: { _ in files },
      now: { clock.now },
      execute: { _, _, _ in
        executions += 1
        return workspace.output.appendingPathComponent("done.pdf")
      })
    let engine = WatchedFolderEngine(
      configuration: try configuration(workspace, settle: 1), stateURL: workspace.stateURL,
      providers: providers)
    var state = AutomationWatchState()
    state.outputs["previous"] = WatchedFolderEngine.canonicalPath(outputFile)
    try engine.saveState(state)
    _ = try engine.scanOnce()
    clock.advance(2)
    let report = try engine.scanOnce()
    #expect(report.processed.count == 1)
    #expect(executions == 1)
    #expect(report.skippedCount >= 3)
    // Outputs recorded in state are never fed back as inputs.
    #expect(report.processed.first?.path.hasSuffix("incoming.pdf") == true)
  }

  @Test func deletedPendingInputsArePruned() throws {
    let workspace = try Workspace()
    defer { workspace.cleanUp() }
    let clock = Clock(Date(timeIntervalSince1970: 2_000_000))
    var files = [snapshot(workspace)]
    let providers = WatchedFolderEngine.Providers(
      listFiles: { _ in files },
      now: { clock.now },
      execute: { _, _, _ in workspace.output.appendingPathComponent("done.pdf") })
    let engine = WatchedFolderEngine(
      configuration: try configuration(workspace, settle: 100), stateURL: workspace.stateURL,
      providers: providers)
    _ = try engine.scanOnce()
    #expect(try engine.loadState().inputs.count == 1)
    files = []
    _ = try engine.scanOnce()
    #expect(try engine.loadState().inputs.isEmpty)
  }

  @Test func reportIsStructuredJSON() throws {
    let workspace = try Workspace()
    defer { workspace.cleanUp() }
    let clock = Clock(Date(timeIntervalSince1970: 2_000_000))
    let providers = WatchedFolderEngine.Providers(
      listFiles: { _ in [self.snapshot(workspace)] },
      now: { clock.now },
      execute: { _, _, _ in workspace.output.appendingPathComponent("done.pdf") })
    let engine = WatchedFolderEngine(
      configuration: try configuration(workspace, settle: 1), stateURL: workspace.stateURL,
      providers: providers)
    _ = try engine.scanOnce()
    clock.advance(2)
    let report = try engine.scanOnce()
    let data = try #require(report.jsonData())
    let object = try #require(
      try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["processed"] is [[String: Any]])
    #expect(object["failed"] is [[String: Any]])
  }

  @Test func realRecipeExecutorProducesAPDFInTheOutputFolder() throws {
    let workspace = try Workspace()
    defer { workspace.cleanUp() }
    let inputPDF = try PDFFixtures.onePage()
    try inputPDF.write(to: workspace.watched.appendingPathComponent("incoming.pdf"))
    let clock = Clock(Date())
    let configuration = try WatchedFolderConfiguration(
      name: "Real export", watchedFolders: [workspace.watched],
      outputFolder: workspace.output,
      recipe: AutomationRecipe(
        name: "Export page 1",
        steps: [AutomationRecipeStep(operation: "export-pages", options: ["--pages": "1"])]),
      settleInterval: 0.01)
    let engine = WatchedFolderEngine(
      configuration: configuration,
      stateURL: workspace.stateURL,
      providers: WatchedFolderEngine.Providers(
        listFiles: WatchedFolderEngine.Providers.live.listFiles,
        now: { clock.now },
        execute: WatchedFolderEngine.Providers.live.execute))
    _ = try engine.scanOnce()
    clock.advance(1)
    let report = try engine.scanOnce()
    #expect(report.failed.isEmpty, "\(report.failed.map(\.message).joined(separator: "; "))")
    #expect(
      report.processed.count == 1,
      "summary=\(report.summary) pending=\(report.pendingCount) already=\(report.alreadyProcessedCount) skipped=\(report.skippedCount)")
    let outputPath = try #require(report.processed.first?.output)
    #expect(FileManager.default.fileExists(atPath: outputPath))
    #expect(outputPath.hasPrefix(WatchedFolderEngine.canonicalPath(workspace.output)))
    let parsed = try PDFParser.parse(try Data(contentsOf: URL(fileURLWithPath: outputPath)))
    #expect(try PDFPageTree.pageIDs(in: parsed.graph).count == 1)
  }
}
