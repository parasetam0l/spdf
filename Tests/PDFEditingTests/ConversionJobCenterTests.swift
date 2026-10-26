import Foundation
import PDFCore
import PDFFixtures
@testable import PDFEditing
import Testing

/// EXP-07: conversion job center with reusable profiles, output naming,
/// overwrite handling, progress, cancellation and per-file fidelity reports.
@Suite("Conversion job center")
struct ConversionJobCenterTests {
  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-conversion-" + UUID().uuidString)
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

  private func textProfile() -> ConversionProfile {
    ConversionProfile(
      name: "Editable text", format: .text, fidelity: .editable,
      namingTemplate: "{name}-{profile}")
  }

  @Test func profileRoundTripsAndRejectsUnknownVersions() throws {
    let profile = textProfile()
    try profile.validate()
    let decoded = try ConversionProfile.decode(from: profile.jsonData())
    #expect(decoded == profile)
    #expect(decoded.scopeDescription == "whole document")

    var appearance = profile
    appearance.fidelity = .appearance
    appearance.format = .html
    #expect(throws: PDFError.self) { try appearance.validate() }
    appearance.acknowledgeAppearanceIsRendered = true
    try appearance.validate()

    let data = try profile.jsonData()
    var text = String(decoding: data, as: UTF8.self)
    text = text.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 99")
    #expect(throws: PDFError.self) {
      _ = try ConversionProfile.decode(from: Data(text.utf8))
    }
  }

  @Test func runConvertsEveryFileWithFidelityLosses() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputs = try writeInputs(3, in: directory)
    let report = try ConversionJobCenter.run(
      inputs: inputs, profile: textProfile(), destination: .besideInput)
    #expect(report.succeededCount == 3)
    #expect(report.failedCount == 0)
    #expect(!report.hasPartialSuccess)
    #expect(report.successInvariantHolds)
    for file in report.files {
      #expect(file.status == .succeeded)
      let data = try Data(contentsOf: URL(fileURLWithPath: try #require(file.outputPath)))
      #expect(ConversionJobCenter.digest(data) == file.outputDigest)
      #expect(!file.fidelityLosses.isEmpty)
      #expect(file.fidelityLosses.contains { $0.contains("Plain text") })
    }
    let outputs = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(!outputs.contains { $0.contains(".partial-") })
  }

  @Test func oneFailureDoesNotInvalidateCompletedOutputs() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputs = try writeInputs(3, in: directory)
    // Pre-create the middle file's output so the fail policy refuses only it.
    let blocked = directory.appendingPathComponent("input-2-editable-text.txt")
    try Data("occupied".utf8).write(to: blocked)
    var profile = textProfile()
    profile.overwrite = .fail
    let report = try ConversionJobCenter.run(
      inputs: inputs, profile: profile, destination: .besideInput)
    #expect(report.succeededCount == 2)
    #expect(report.failedCount == 1)
    #expect(report.hasPartialSuccess)
    #expect(report.files[1].status == .failed)
    #expect(report.files[1].outputPath == nil)
    #expect(report.files[0].status == .succeeded)
    #expect(report.files[2].status == .succeeded)
    #expect(report.files[0].outputPath != nil)
    #expect(report.files[2].outputPath != nil)
    // The blocked file is untouched and the later conversion still completed.
    #expect(try Data(contentsOf: blocked) == Data("occupied".utf8))
    #expect(FileManager.default.fileExists(atPath: report.files[2].outputPath ?? ""))
  }

  @Test func uniqueSuffixPolicyKeepsBothRuns() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputs = try writeInputs(1, in: directory)
    let first = try ConversionJobCenter.run(
      inputs: inputs, profile: textProfile(), destination: .besideInput)
    let second = try ConversionJobCenter.run(
      inputs: inputs, profile: textProfile(), destination: .besideInput)
    let firstURL = URL(fileURLWithPath: try #require(first.files[0].outputPath))
    let secondURL = URL(fileURLWithPath: try #require(second.files[0].outputPath))
    #expect(firstURL != secondURL)
    #expect(secondURL.lastPathComponent == "input-1-editable-text-2.txt")
    #expect(FileManager.default.fileExists(atPath: firstURL.path))
  }

  @Test func cancellationStopsCleanlyAndKeepsCompletedOutputs() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputs = try writeInputs(3, in: directory)
    let cancellation = ConversionCancellation()
    let report = try ConversionJobCenter.run(
      inputs: inputs, profile: textProfile(), destination: .besideInput,
      cancellation: cancellation,
      progress: { progress in
        if progress.stage == .writing, progress.fileIndex == 0 {
          cancellation.requestCancel()
        }
      })
    #expect(report.cancelled)
    #expect(report.succeededCount == 1)
    #expect(report.cancelledCount == 2)
    #expect(report.files[0].status == .succeeded)
    #expect(report.files[1].status == .cancelled)
    #expect(report.files[1].outputPath == nil)

    // Cancelling before any work leaves no output at all.
    let emptyDirectory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: emptyDirectory) }
    let emptyInputs = try writeInputs(2, in: emptyDirectory)
    let preCancelled = ConversionCancellation()
    preCancelled.requestCancel()
    let emptyReport = try ConversionJobCenter.run(
      inputs: emptyInputs, profile: textProfile(), destination: .besideInput,
      cancellation: preCancelled)
    #expect(emptyReport.succeededCount == 0)
    #expect(emptyReport.cancelledCount == 2)
    let names = try FileManager.default.contentsOfDirectory(atPath: emptyDirectory.path)
    #expect(!names.contains { $0.hasSuffix(".txt") })
  }

  @Test func pageRangeAndFolderDestinationAreAppliedPerFile() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let outputDirectory = directory.appendingPathComponent("out")
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let inputs = try writeInputs(2, in: directory)
    var profile = textProfile()
    profile.scope = .pageRange
    profile.pageRangeStart = 2
    profile.pageRangeEnd = 2
    let report = try ConversionJobCenter.run(
      inputs: inputs, profile: profile,
      destination: ConversionDestination(folderURL: outputDirectory))
    #expect(report.succeededCount == 2)
    for file in report.files {
      let url = URL(fileURLWithPath: try #require(file.outputPath))
      #expect(url.deletingLastPathComponent().standardizedFileURL == outputDirectory.standardizedFileURL)
      let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
      #expect(text.contains("page 2"))
      #expect(!text.contains("page 1"))
    }
  }

  @Test func previewResolvesNamesAndShowsRefusals() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputs = try writeInputs(2, in: directory)
    let preview = try ConversionJobCenter.preview(
      inputs: inputs, profile: textProfile(), destination: .besideInput)
    #expect(preview.count == 2)
    #expect(preview[0].refusal == nil)
    #expect(preview[0].outputURL?.lastPathComponent == "input-1-editable-text.txt")

    var failing = textProfile()
    failing.overwrite = .fail
    let blocked = directory.appendingPathComponent("input-1-editable-text.txt")
    try Data("occupied".utf8).write(to: blocked)
    let refused = try ConversionJobCenter.preview(
      inputs: [inputs[0]], profile: failing, destination: .besideInput)
    #expect(refused[0].refusal != nil)
    #expect(refused[0].outputURL == nil)
  }

  @Test func appearanceProfileRequiresRendererPerFile() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputs = try writeInputs(1, in: directory)
    var profile = ConversionProfile(
      name: "Rendered", format: .html, fidelity: .appearance,
      namingTemplate: "{name}-{profile}", acknowledgeAppearanceIsRendered: true)
    try profile.validate()
    let report = try ConversionJobCenter.run(
      inputs: inputs, profile: profile, destination: .besideInput)
    #expect(report.succeededCount == 0)
    #expect(report.files[0].status == .failed)
    #expect(report.files[0].failure?.contains("appearance renderer") == true)

    let renderer = AppearanceRenderer { _ in
      AppearanceImage(
        pngData: Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: 0, count: 8)),
        pixelWidth: 8, pixelHeight: 8)
    }
    let rendered = try ConversionJobCenter.run(
      inputs: inputs, profile: profile, destination: .besideInput,
      appearanceRenderer: renderer)
    #expect(rendered.succeededCount == 1)
    let text = String(
      decoding: try Data(contentsOf: URL(fileURLWithPath: try #require(rendered.files[0].outputPath))),
      as: UTF8.self)
    #expect(text.contains("data:image/png;base64,"))
    #expect(rendered.files[0].fidelity == .appearance)
  }

  @Test func markdownAndJSONReportsCarryPerFileOutcomes() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputs = try writeInputs(2, in: directory)
    let report = try ConversionJobCenter.run(
      inputs: inputs, profile: textProfile(), destination: .besideInput)
    let markdown = report.markdown()
    #expect(markdown.contains("# Conversion job: Editable text"))
    #expect(markdown.contains("| File | Status | Output | Fidelity losses |"))
    #expect(markdown.contains("Succeeded"))
    #expect(!report.hasPartialSuccess)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ConversionJobReport.self, from: try report.jsonData())
    #expect(decoded.succeededCount == 2)
    #expect(decoded.files.map(\.inputName) == report.files.map(\.inputName))
    #expect(decoded.successInvariantHolds)
    #expect(decoded.files.allSatisfy { !$0.fidelityLosses.isEmpty })
  }
}
