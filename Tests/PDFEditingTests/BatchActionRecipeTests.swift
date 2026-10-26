import Foundation
import PDFCore
import PDFFixtures
@testable import PDFEditing
import Testing

/// AUT-03: recipe composition, validation, preview and sharing.
@Suite("Batch action recipes")
struct BatchActionRecipeTests {
  private func recipe(
    name: String = "Archive batch",
    steps: [BatchRecipeStep]? = nil
  ) -> BatchRecipe {
    BatchRecipe(
      name: name,
      steps: steps ?? [
        BatchRecipeStep(kind: .batesNumbering),
        BatchRecipeStep(kind: .optimize),
        BatchRecipeStep(kind: .preflight),
      ])
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-batch-recipe-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func writePDF(_ data: Data, named name: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try data.write(to: url)
    return url
  }

  @Test func validRecipeValidates() throws {
    try recipe().validate()
    #expect(recipe().enabledSteps.count == 3)
    #expect(recipe().outputExtension == "pdf")
    #expect(recipe().terminalExport == nil)
  }

  @Test func recipeRejectsInvalidComposition() throws {
    // Empty step list.
    #expect(throws: PDFError.self) {
      try BatchRecipe(name: "Empty", steps: []).validate()
    }
    // Export step must be last.
    #expect(throws: PDFError.self) {
      try recipe(steps: [
        BatchRecipeStep(kind: .exportText),
        BatchRecipeStep(kind: .optimize),
      ]).validate()
    }
    // At most one export.
    #expect(throws: PDFError.self) {
      try recipe(steps: [
        BatchRecipeStep(kind: .exportText),
        BatchRecipeStep(kind: .exportDOCX),
      ]).validate()
    }
    // Invalid settings (Bates digits out of range).
    var badBates = BatchBatesSettings()
    badBates.digits = 40
    #expect(throws: PDFError.self) {
      try recipe(steps: [
        BatchRecipeStep(kind: .batesNumbering, bates: badBates)
      ]).validate()
    }
    // All steps disabled.
    var disabled = BatchRecipeStep(kind: .optimize)
    disabled.enabled = false
    #expect(throws: PDFError.self) {
      try BatchRecipe(name: "Disabled", steps: [disabled]).validate()
    }
  }

  @Test func recipeRoundTripsThroughSharedJSON() throws {
    let original = recipe(name: "Batch for review")
    let data = try original.jsonData()
    let decoded = try BatchRecipe.decode(from: data)
    #expect(decoded == original)
    #expect(decoded.digest == original.digest)
    #expect(String(decoding: data, as: UTF8.self).contains("schemaVersion"))
    #expect(String(decoding: data, as: UTF8.self).contains("batesNumbering"))
    // No executable/script concept exists in the shared format.
    #expect(!String(decoding: data, as: UTF8.self).lowercased().contains("script"))
  }

  @Test func unknownSchemaVersionIsRefused() throws {
    let data = try recipe().jsonData()
    var text = String(decoding: data, as: UTF8.self)
    text = text.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 99")
    #expect(throws: PDFError.self) {
      try BatchRecipe.decode(from: Data(text.utf8))
    }
    #expect(throws: PDFError.self) {
      try BatchRecipe.decode(from: Data("not a recipe".utf8))
    }
  }

  @Test func destinationPolicyResolvesNamesAndRefusesInputOverwrite() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputs = [
      try writePDF(try PDFFixtures.onePage(), named: "one.pdf", in: directory),
      try writePDF(try PDFFixtures.onePage(), named: "two.pdf", in: directory),
    ]
    let policy = BatchDestinationPolicy(
      mode: .besideInput, nameTemplate: "{name}-{recipe}")
    let outputs = try BatchPlanner.resolveOutputs(
      recipe: recipe(name: "Archive"), inputs: inputs, destination: policy)
    #expect(outputs.count == 2)
    #expect(outputs[0].lastPathComponent == "one-archive.pdf")
    #expect(outputs[1].lastPathComponent == "two-archive.pdf")
    #expect(outputs[0].deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)

    // A template that resolves to the input name is always refused.
    #expect(throws: PDFError.self) {
      _ = try BatchPlanner.resolveOutputs(
        recipe: recipe(name: "Archive"), inputs: inputs,
        destination: BatchDestinationPolicy(mode: .besideInput, nameTemplate: "{name}"))
    }
    // Even when replacing existing outputs is allowed, inputs still refuse.
    #expect(throws: PDFError.self) {
      _ = try BatchPlanner.resolveOutputs(
        recipe: recipe(name: "Archive"), inputs: inputs,
        destination: BatchDestinationPolicy(
          mode: .besideInput, overwriteExistingOutputs: true, nameTemplate: "{name}"))
    }
  }

  @Test func collisionPoliciesAreExplicit() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = try writePDF(try PDFFixtures.onePage(), named: "one.pdf", in: directory)
    let existing = directory.appendingPathComponent("one-archive.pdf")
    try Data("occupied".utf8).write(to: existing)

    let unique = try BatchPlanner.resolveOutputs(
      recipe: recipe(name: "Archive"), inputs: [input],
      destination: BatchDestinationPolicy(mode: .besideInput, nameTemplate: "{name}-{recipe}"))
    #expect(unique[0].lastPathComponent == "one-archive-2.pdf")

    #expect(throws: PDFError.self) {
      _ = try BatchPlanner.resolveOutputs(
        recipe: recipe(name: "Archive"), inputs: [input],
        destination: BatchDestinationPolicy(
          mode: .besideInput, collision: .fail, nameTemplate: "{name}-{recipe}"))
    }

    let overwrite = try BatchPlanner.resolveOutputs(
      recipe: recipe(name: "Archive"), inputs: [input],
      destination: BatchDestinationPolicy(
        mode: .besideInput, overwriteExistingOutputs: true,
        nameTemplate: "{name}-{recipe}"))
    #expect(overwrite[0].lastPathComponent == "one-archive.pdf")
  }

  @Test func folderDestinationAndOutputExtensionFollowTerminalStep() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let outputDirectory = directory.appendingPathComponent("out")
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let input = try writePDF(try PDFFixtures.onePage(), named: "one.pdf", in: directory)
    let textRecipe = recipe(
      name: "Text batch",
      steps: [
        BatchRecipeStep(kind: .optimize),
        BatchRecipeStep(kind: .exportText),
      ])
    let outputs = try BatchPlanner.resolveOutputs(
      recipe: textRecipe, inputs: [input],
      destination: BatchDestinationPolicy(
        mode: .folder, folderPath: outputDirectory.path, nameTemplate: "{recipe}-{name}"))
    #expect(outputs[0].lastPathComponent == "text-batch-one.txt")
    #expect(outputs[0].deletingLastPathComponent().standardizedFileURL == outputDirectory.standardizedFileURL)
  }

  @Test func previewShowsPlanPerFileAndMissingService() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputs = [
      try writePDF(try PDFFixtures.onePage(), named: "one.pdf", in: directory),
      try writePDF(try PDFFixtures.threePages(), named: "two.pdf", in: directory),
    ]
    let preview = try BatchPlanner.preview(
      recipe: recipe(), inputs: inputs,
      destination: BatchDestinationPolicy(mode: .besideInput, nameTemplate: "{name}-{recipe}"))
    #expect(preview.files.count == 2)
    #expect(preview.readyCount == 2)
    #expect(preview.canRun)
    #expect(preview.files[0].pageCount == 1)
    #expect(preview.files[1].pageCount == 3)
    #expect(preview.files[0].outputURL?.lastPathComponent == "one-archive-batch.pdf")
    #expect(preview.files[0].stepSummaries.count == 3)

    // OCR is service-provided: the preview names the missing service instead
    // of silently dropping the step.
    let ocrRecipe = BatchRecipe(name: "OCR batch", steps: [
      BatchRecipeStep(kind: .ocr),
      BatchRecipeStep(kind: .optimize),
    ])
    let ocrPreview = try BatchPlanner.preview(
      recipe: ocrRecipe, inputs: inputs,
      destination: BatchDestinationPolicy(mode: .besideInput, nameTemplate: "{name}-ocr"))
    #expect(!ocrPreview.canRun)
    #expect(ocrPreview.warnings.contains { $0.contains("OCR") })
    #expect(ocrPreview.files[0].refusals.contains { $0.contains("service performer") })
  }

  @Test func exportRequiresServicePerformerWhereDeclared() throws {
    let docxRecipe = BatchRecipe(name: "DOCX", steps: [BatchRecipeStep(kind: .exportDOCX)])
    #expect(docxRecipe.enabledSteps.first?.kind.requiresService == true)
    #expect(BatchRecipeStep(kind: .batesNumbering).kind.requiresService == false)
    #expect(BatchStandardPerformers.registry().missingKinds(for: docxRecipe) == [.exportDOCX])
    #expect(BatchStandardPerformers.registry().missingKinds(for: recipe()).isEmpty)
  }
}
