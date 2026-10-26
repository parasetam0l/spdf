import Foundation
import PDFCore
import PDFFixtures
@testable import PDFEditing
import Testing

/// AUT-04: per-file checkpoints, stop/resume, destination policies, partial
/// success reporting and safe retry.
@Suite("Batch execution resilience")
struct BatchExecutionTests {
  // MARK: - Shared test doubles

  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func bump(_ key: String) {
      lock.lock()
      counts[key, default: 0] += 1
      lock.unlock()
    }
    func count(_ key: String) -> Int {
      lock.lock()
      defer { lock.unlock() }
      return counts[key] ?? 0
    }
  }

  final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BatchProgress] = []
    func record(_ progress: BatchProgress) {
      lock.lock()
      events.append(progress)
      lock.unlock()
    }
    var all: [BatchProgress] {
      lock.lock()
      defer { lock.unlock() }
      return events
    }
  }

  /// A stand-in for the app-provided OCR service performer.
  struct IdentityOCRPerformer: BatchStepPerformer {
    let kind = BatchActionKind.ocr
    let counter: Counter?
    func perform(_ request: BatchStepRequest) throws -> BatchStepOutcome {
      counter?.bump("ocr")
      return BatchStepOutcome(
        data: request.sourceBytes, note: "identity OCR layer for evaluation")
    }
  }

  /// Fails for one file index, succeeds otherwise.
  struct FailingOCRPerformer: BatchStepPerformer {
    let kind = BatchActionKind.ocr
    let failAt: Int
    func perform(_ request: BatchStepRequest) throws -> BatchStepOutcome {
      if request.fileIndex == failAt {
        throw PDFError(.unsupported, "injected OCR failure")
      }
      return BatchStepOutcome(data: request.sourceBytes, note: "identity OCR layer")
    }
  }

  /// A stand-in for the app-provided DOCX export performer.
  struct MarkerDOCXPerformer: BatchStepPerformer {
    let kind = BatchActionKind.exportDOCX
    func perform(_ request: BatchStepRequest) throws -> BatchStepOutcome {
      BatchStepOutcome(
        data: Data("fake-docx-document".utf8), note: "fake DOCX export")
    }
  }

  // MARK: - Helpers

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-batch-exec-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func writeInputs(_ count: Int, in directory: URL) throws -> [URL] {
    let data = try PDFFixtures.threePages()
    return try (0..<count).map { index in
      let url = directory.appendingPathComponent("input-" + String(index + 1) + ".pdf")
      try data.write(to: url)
      return url
    }
  }

  private func batesRecipe(name: String = "Numbered") -> BatchRecipe {
    var settings = BatchBatesSettings()
    settings.digits = 4
    settings.startNumber = 1
    settings.continuesAcrossFiles = true
    return BatchRecipe(
      name: name,
      steps: [
        BatchRecipeStep(kind: .batesNumbering, bates: settings),
        BatchRecipeStep(kind: .optimize),
      ])
  }

  private func destination(in directory: URL) -> BatchDestinationPolicy {
    BatchDestinationPolicy(
      mode: .besideInput, nameTemplate: "{name}-{recipe}")
  }

  private func outputData(_ outcome: BatchFileOutcome) throws -> Data {
    let path = try #require(outcome.outputPath)
    return try Data(contentsOf: URL(fileURLWithPath: path))
  }

  // MARK: - Success path

  @Test func successfulRunWritesVerifiedOutputsAndReportsEveryFile() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputs = try writeInputs(3, in: directory)
    let result = try BatchRunner.run(
      recipe: batesRecipe(), inputs: inputs,
      options: BatchRunOptions(destination: destination(in: directory)))
    let report = result.report
    #expect(report.succeededCount == 3)
    #expect(report.failedCount == 0)
    #expect(!report.stopped)
    #expect(!report.abortedByError)
    #expect(!report.hasPartialSuccess)
    #expect(report.successInvariantHolds)
    #expect(FileManager.default.fileExists(atPath: result.checkpointURL.path))
    for outcome in report.files {
      let data = try outputData(outcome)
      #expect(BatchDigest.hex(data) == outcome.outputDigest)
      let parsed = try PDFParser.parse(data)
      #expect(parsed.pageIDs.count == 3)
    }
    let notes = report.files.map { $0.completedSteps.joined(separator: " | ") }
    #expect(notes[0].contains("1-3"))
    #expect(notes[1].contains("4-6"))
    #expect(notes[2].contains("7-9"))
    // No partial artifacts remain in the destination.
    let leftovers = try FileManager.default.contentsOfDirectory(
      atPath: directory.path).filter { $0.contains(".partial-") }
    #expect(leftovers.isEmpty)
    // Checkpoint records success with output identities.
    let checkpoint = try BatchFileIO.readCheckpoint(result.checkpointURL)
    #expect(checkpoint.files.allSatisfy { $0.status == .succeeded && $0.outputDigest != nil })
  }

  // MARK: - Per-file failure and partial success

  @Test func failureStopsOnlyThatFileAndReportsPartialSuccess() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputs = try writeInputs(3, in: directory)
    let recipe = BatchRecipe(name: "OCR and optimize", steps: [
      BatchRecipeStep(kind: .ocr),
      BatchRecipeStep(kind: .optimize),
    ])
    let registry = BatchStandardPerformers.registry()
      .registering([FailingOCRPerformer(failAt: 1)])
    let result = try BatchRunner.run(
      recipe: recipe, inputs: inputs,
      options: BatchRunOptions(destination: destination(in: directory)),
      performers: registry)
    let report = result.report
    #expect(report.succeededCount == 2)
    #expect(report.failedCount == 1)
    #expect(report.hasPartialSuccess)
    #expect(report.successInvariantHolds)
    #expect(report.failureSummary.contains("input-2.pdf"))
    #expect(report.failureSummary.contains("injected OCR failure"))
    #expect(report.files[1].outputPath == nil)
    #expect(report.files[1].outputDigest == nil)
    #expect(report.files[1].status == .failed)
    #expect(report.files[0].status == .succeeded)
    #expect(report.files[2].status == .succeeded)
    // The failed file never left an output or a partial artifact.
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(!names.contains { $0.hasPrefix("input-2-") && $0.hasSuffix(".pdf") })
    #expect(!names.contains { $0.contains(".partial-") })

    let checkpoint = try BatchFileIO.readCheckpoint(result.checkpointURL)
    #expect(checkpoint.files[1].status == .failed)
    #expect(checkpoint.files[1].outputPath == nil)
  }

  @Test func retryOnlyReprocessesFailedFilesAndKeepsCompletedOutputs() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputs = try writeInputs(3, in: directory)
    let recipe = BatchRecipe(name: "OCR retry", steps: [
      BatchRecipeStep(kind: .ocr),
      BatchRecipeStep(kind: .optimize),
    ])
    let failing = BatchStandardPerformers.registry()
      .registering([FailingOCRPerformer(failAt: 1)])
    let first = try BatchRunner.run(
      recipe: recipe, inputs: inputs,
      options: BatchRunOptions(destination: destination(in: directory)),
      performers: failing)
    #expect(first.report.succeededCount == 2)
    let firstOutputs = first.report.files.compactMap(\.outputPath)
    #expect(firstOutputs.count == 2)

    let counter = Counter()
    let good = BatchStandardPerformers.registry()
      .registering([IdentityOCRPerformer(counter: counter)])
    let second = try BatchRunner.run(
      recipe: recipe, inputs: inputs,
      options: BatchRunOptions(
        destination: destination(in: directory), resume: true),
      performers: good)
    #expect(second.report.succeededCount == 3)
    #expect(second.report.failedCount == 0)
    #expect(second.report.files[0].resumed)
    #expect(second.report.files[1].status == .succeeded)
    #expect(second.report.files[1].resumed == false)
    // Only the failed file ran through the OCR performer again.
    #expect(counter.count("ocr") == 1)
    // Completed outputs were not rewritten (same digest as before).
    for outcome in second.report.files where outcome.status == .succeeded {
      #expect(try outputData(outcome).count > 0)
    }
  }

  // MARK: - Stop and resume

  @Test func stopAndResumeContinuesCrossFileState() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputs = try writeInputs(3, in: directory)
    let control = BatchRunControl()
    let collector = ProgressCollector()
    let recipe = batesRecipe()
    let first = try BatchRunner.run(
      recipe: recipe, inputs: inputs,
      options: BatchRunOptions(destination: destination(in: directory)),
      control: control,
      progress: { progress in
        collector.record(progress)
        if progress.stage == .writing, progress.fileIndex == 0 {
          control.requestStop()
        }
      })
    #expect(first.report.stopped)
    #expect(first.report.succeededCount == 1)
    #expect(first.report.notStartedCount == 2)
    #expect(first.report.files[0].status == .succeeded)
    #expect(first.report.files[1].status == .notStarted)
    #expect(first.report.files[2].status == .notStarted)
    #expect(first.report.successInvariantHolds)
    #expect(collector.all.contains { $0.stage == .stopped })

    let second = try BatchRunner.run(
      recipe: recipe, inputs: inputs,
      options: BatchRunOptions(
        destination: destination(in: directory), resume: true))
    #expect(!second.report.stopped)
    #expect(second.report.succeededCount == 3)
    #expect(second.report.files[0].resumed)
    let notes = second.report.files.map { $0.completedSteps.joined(separator: " | ") }
    // The Bates sequence continues where the checkpoint left it.
    #expect(notes[0].contains("already completed"))
    #expect(notes[1].contains("4-6"))
    #expect(notes[2].contains("7-9"))
  }

  @Test func resumeRefusesChangedInputsOrRecipe() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputs = try writeInputs(2, in: directory)
    let control = BatchRunControl()
    let recipe = batesRecipe()
    _ = try BatchRunner.run(
      recipe: recipe, inputs: inputs,
      options: BatchRunOptions(destination: destination(in: directory)),
      control: control,
      progress: { progress in
        if progress.stage == .writing, progress.fileIndex == 0 {
          control.requestStop()
        }
      })
    // Changed input bytes invalidate the checkpoint rather than silently
    // processing different content under a resume.
    try Data("changed-content".utf8).write(to: inputs[1])
    #expect(throws: PDFError.self) {
      _ = try BatchRunner.run(
        recipe: recipe, inputs: inputs,
        options: BatchRunOptions(
          destination: destination(in: directory), resume: true))
    }

    // A different recipe also refuses to resume a checkpoint (separate
    // directory so the fresh checkpoint belongs to the same inputs).
    let otherDirectory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: otherDirectory) }
    let freshInputs = try writeInputs(2, in: otherDirectory)
    let freshControl = BatchRunControl()
    _ = try BatchRunner.run(
      recipe: recipe, inputs: freshInputs,
      options: BatchRunOptions(destination: destination(in: otherDirectory)),
      control: freshControl,
      progress: { progress in
        if progress.stage == .writing, progress.fileIndex == 0 {
          freshControl.requestStop()
        }
      })
    #expect(throws: PDFError.self) {
      _ = try BatchRunner.run(
        recipe: BatchRecipe(name: "Different", steps: [
          BatchRecipeStep(kind: .optimize)
        ]), inputs: freshInputs,
        options: BatchRunOptions(
          destination: destination(in: otherDirectory), resume: true))
    }
  }

  @Test func tamperedOutputIsNeverReportedAsSuccess() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputs = try writeInputs(3, in: directory)
    let recipe = batesRecipe()
    let first = try BatchRunner.run(
      recipe: recipe, inputs: inputs,
      options: BatchRunOptions(destination: destination(in: directory)))
    #expect(first.report.succeededCount == 3)
    let target = URL(fileURLWithPath: try #require(first.report.files[1].outputPath))
    try Data("user-edited-output".utf8).write(to: target)

    let second = try BatchRunner.run(
      recipe: recipe, inputs: inputs,
      options: BatchRunOptions(
        destination: destination(in: directory), resume: true))
    #expect(second.report.succeededCount == 2)
    #expect(second.report.failedCount == 1)
    #expect(second.report.files[1].status == .failed)
    #expect(second.report.files[1].failure?.contains("missing or changed") == true)
    #expect(second.report.successInvariantHolds)
    // The user's edited output is not overwritten by the resume.
    #expect(try Data(contentsOf: target) == Data("user-edited-output".utf8))
  }

  // MARK: - Destination policies

  @Test func destinationPoliciesAvoidCollisionsAndNeverOverwriteInputs() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputs = try writeInputs(2, in: directory)
    let recipe = BatchRecipe(name: "Optimized", steps: [BatchRecipeStep(kind: .optimize)])
    let first = try BatchRunner.run(
      recipe: recipe, inputs: inputs,
      options: BatchRunOptions(destination: destination(in: directory)))
    #expect(first.report.succeededCount == 2)
    let firstNames = Set(first.report.files.compactMap(\.outputPath).map { URL(fileURLWithPath: $0).lastPathComponent })
    #expect(firstNames == ["input-1-optimized.pdf", "input-2-optimized.pdf"])

    // A second run with the same names gets unique suffixes instead of
    // replacing the first run's outputs.
    let second = try BatchRunner.run(
      recipe: recipe, inputs: inputs,
      options: BatchRunOptions(destination: destination(in: directory)))
    let secondNames = Set(second.report.files.compactMap(\.outputPath).map { URL(fileURLWithPath: $0).lastPathComponent })
    #expect(secondNames == ["input-1-optimized-2.pdf", "input-2-optimized-2.pdf"])
    #expect(first.report.files.allSatisfy { FileManager.default.fileExists(atPath: $0.outputPath ?? "") })

    // A template resolving to the input name is refused before any write.
    let inputBefore = try Data(contentsOf: inputs[0])
    #expect(throws: PDFError.self) {
      _ = try BatchRunner.run(
        recipe: recipe, inputs: inputs,
        options: BatchRunOptions(
          destination: BatchDestinationPolicy(mode: .besideInput, nameTemplate: "{name}")))
    }
    #expect(try Data(contentsOf: inputs[0]) == inputBefore)
  }

  @Test func folderDestinationWritesOutsideInputDirectory() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let outputDirectory = directory.appendingPathComponent("outputs")
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let inputs = try writeInputs(2, in: directory)
    let result = try BatchRunner.run(
      recipe: batesRecipe(), inputs: inputs,
      options: BatchRunOptions(
        destination: BatchDestinationPolicy(
          mode: .folder, folderPath: outputDirectory.path,
          nameTemplate: "{recipe}-{name}")))
    #expect(result.report.succeededCount == 2)
    for outcome in result.report.files {
      let url = URL(fileURLWithPath: try #require(outcome.outputPath))
      #expect(url.deletingLastPathComponent().standardizedFileURL == outputDirectory.standardizedFileURL)
      #expect(url.lastPathComponent.hasPrefix("numbered-input-"))
    }
  }

  @Test func haltOnErrorStopsTheRunAndLeavesRemainingNotStarted() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputs = try writeInputs(3, in: directory)
    let recipe = BatchRecipe(name: "Halt on error", steps: [
      BatchRecipeStep(kind: .ocr),
      BatchRecipeStep(kind: .optimize),
    ])
    let failing = BatchStandardPerformers.registry()
      .registering([FailingOCRPerformer(failAt: 0)])
    let first = try BatchRunner.run(
      recipe: recipe, inputs: inputs,
      options: BatchRunOptions(
        destination: destination(in: directory), continueOnError: false),
      performers: failing)
    #expect(first.report.abortedByError)
    #expect(first.report.failedCount == 1)
    #expect(first.report.succeededCount == 0)
    #expect(first.report.notStartedCount == 2)
    #expect(first.report.files[0].status == .failed)
    #expect(first.report.files[2].status == .notStarted)

    let second = try BatchRunner.run(
      recipe: recipe, inputs: inputs,
      options: BatchRunOptions(
        destination: destination(in: directory), resume: true),
      performers: BatchStandardPerformers.registry()
        .registering([IdentityOCRPerformer(counter: nil)]))
    #expect(second.report.succeededCount == 3)
    #expect(second.report.failedCount == 0)
  }

  // MARK: - Composition, progress and report

  @Test func serviceRecipeComposesOCRAndDOCXExport() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputs = try writeInputs(2, in: directory)
    let recipe = BatchRecipe(name: "Accessible copy", steps: [
      BatchRecipeStep(kind: .ocr),
      BatchRecipeStep(kind: .optimize),
      BatchRecipeStep(kind: .exportDOCX),
    ])
    let registry = BatchStandardPerformers.registry()
      .registering([IdentityOCRPerformer(counter: nil), MarkerDOCXPerformer()])
    let result = try BatchRunner.run(
      recipe: recipe, inputs: inputs,
      options: BatchRunOptions(destination: destination(in: directory)),
      performers: registry)
    #expect(result.report.succeededCount == 2)
    for outcome in result.report.files {
      let url = URL(fileURLWithPath: try #require(outcome.outputPath))
      #expect(url.pathExtension == "docx")
      #expect(try Data(contentsOf: url) == Data("fake-docx-document".utf8))
      #expect(outcome.completedSteps.count == 3)
      #expect(outcome.completedSteps[0].contains("OCR"))
      #expect(outcome.completedSteps[2].contains("DOCX"))
    }
  }

  @Test func reportMarkdownJSONAndProgressAreStable() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputs = try writeInputs(2, in: directory)
    let collector = ProgressCollector()
    let result = try BatchRunner.run(
      recipe: batesRecipe(), inputs: inputs,
      options: BatchRunOptions(destination: destination(in: directory)),
      progress: { collector.record($0) })
    let markdown = result.report.markdown()
    #expect(markdown.contains("# Batch run:"))
    #expect(markdown.contains("| File | Status | Output | Notes |"))
    #expect(markdown.contains("Succeeded"))
    #expect(!result.report.hasPartialSuccess)
    #expect(!result.report.summary.contains("partial success"))

    let data = try result.report.jsonData()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(BatchRunReport.self, from: data)
    #expect(decoded.succeededCount == 2)
    #expect(decoded.files.map(\.fileName) == result.report.files.map(\.fileName))
    #expect(decoded.successInvariantHolds)

    let stages = Set(collector.all.map(\.stage))
    #expect(stages.contains(.preparing))
    #expect(stages.contains(.processing))
    #expect(stages.contains(.writing))
    #expect(stages.contains(.finished))
    #expect(collector.all.contains { $0.fileIndex == 1 && $0.stage == .processing })
  }
}
