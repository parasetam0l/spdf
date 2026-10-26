import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// AUT-07: portable recipe validation, version migration, explicit
/// incompatibilities, no-code policy, deterministic export and report.
@Suite("Recipe portability")
struct RecipePortabilityTests {
  private func recipe(
    version: Int = RecipeDocument.currentVersion, name: String = "Batch export",
    operations: [RecipeOperation], metadata: [String: String] = [:]
  ) -> RecipeDocument {
    RecipeDocument(
      version: version, name: name, appVersion: "0.1.6", operations: operations,
      metadata: metadata)
  }

  private func exportData(_ recipe: RecipeDocument) throws -> Data {
    try RecipePortability.export(recipe)
  }

  private func validate(_ json: String) throws -> RecipeValidation {
    try RecipePortability.validate(data: Data(json.utf8))
  }

  @Test func validRecipeRoundTripsDeterministically() throws {
    let recipe = recipe(
      operations: [
        RecipeOperation(
          type: "ocr.recognize", label: "OCR",
          settings: [
            "pages": .list([.string("1-3"), .string("7")]),
            "level": .string("accurate"),
          ]),
        RecipeOperation(
          type: "export.tables",
          settings: ["destination": .string("out/tables.xlsx"), "format": .string("xlsx")]),
      ],
      metadata: ["author": "Fixture Author"])
    let data = try exportData(recipe)
    let second = try exportData(recipe)
    #expect(data == second, "export is deterministic")
    let validation = try RecipePortability.validate(data: data)
    #expect(validation.isAccepted)
    #expect(validation.errors.isEmpty)
    #expect(validation.migratedFromVersion == nil)
    let decoded = try #require(validation.recipe)
    #expect(decoded.version == RecipeDocument.currentVersion)
    #expect(decoded.name == recipe.name)
    #expect(decoded.operations == recipe.operations)
    #expect(decoded.metadata == recipe.metadata)
    let report = RecipePortability.compatibilityReport(validation)
    #expect(report.contains("Status: accepted"))
    #expect(report.contains("ocr.recognize"))
    #expect(report.contains("declarative"))
    // The serialized form is sorted JSON data, not a script or a URL.
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"operations\""))
    #expect(text.contains("\"version\" : 1"))
    #expect(!text.lowercased().contains("javascript:"))
  }

  @Test func olderVersionMigratesWithDeclaredDefaults() throws {
    let legacy = """
      {
        "version": 0,
        "title": "Legacy batch",
        "createdBy": "old build",
        "notesFromOldBuild": "ignored legacy note",
        "tasks": [
          { "kind": "ocr.batch", "config": { "scope": "all" }, "title": "OCR all" },
          { "kind": "export.text", "config": { "destination": "out/text.txt" } }
        ]
      }
      """
    let validation = try validate(legacy)
    #expect(validation.isAccepted)
    #expect(validation.migratedFromVersion == 0)
    let migrated = try #require(validation.recipe)
    #expect(migrated.version == RecipeDocument.currentVersion)
    #expect(migrated.name == "Legacy batch")
    #expect(migrated.operations.map(\.type) == ["ocr.batch", "export.text"])
    #expect(validation.warnings.contains { $0.code == "legacyLayout" })
    #expect(validation.warnings.contains { $0.code == "migratedVersion" })
    #expect(validation.warnings.contains { $0.code == "unknownTopLevelKey" })
    let report = RecipePortability.compatibilityReport(validation)
    #expect(report.contains("migrated from v0"))
  }

  @Test func newerVersionIsRefusedWithExplanation() throws {
    let validation = try validate(
      """
      { "version": 9, "name": "From the future", "operations": [] }
      """)
    #expect(!validation.isAccepted)
    let error = try #require(validation.errors.first)
    #expect(error.code == "unsupportedVersion")
    #expect(error.message.contains("Nothing was imported"))
    let report = RecipePortability.compatibilityReport(validation)
    #expect(report.contains("not imported"))
  }

  @Test func unknownOperationIsExplained() throws {
    let validation = try validate(
      """
      {
        "version": 1,
        "name": "Unknown op",
        "operations": [ { "type": "shell.run", "settings": { "command": "rm -rf /" } } ]
      }
      """)
    #expect(!validation.isAccepted)
    #expect(validation.errors.contains { $0.code == "unsupportedOperation" })
    let report = RecipePortability.compatibilityReport(validation)
    #expect(report.contains("shell.run"))
    #expect(report.contains("not supported"))
  }

  @Test func codeAndNetworkDirectivesAreRefused() throws {
    let script = try validate(
      """
      {
        "version": 1,
        "name": "Script",
        "operations": [ {
          "type": "export.text",
          "settings": { "destination": "out.txt", "script": "javascript:alert(1)" }
        } ]
      }
      """)
    #expect(!script.isAccepted)
    #expect(script.errors.contains { $0.code == "forbiddenKey" })

    let metadata = try validate(
      """
      {
        "version": 1,
        "name": "Metadata code",
        "operations": [],
        "metadata": { "command": "curl https://example.com" }
      }
      """)
    #expect(!metadata.isAccepted)
    #expect(metadata.errors.contains { $0.code == "forbiddenKey" })

    let valuePrefix = try validate(
      """
      {
        "version": 1,
        "name": "Directive value",
        "operations": [ {
          "type": "export.text",
          "settings": { "destination": "javascript:alert(1)" }
        } ]
      }
      """)
    #expect(!valuePrefix.isAccepted)
    #expect(valuePrefix.errors.contains { $0.code == "invalidSetting" })
  }

  @Test func unknownSettingsAreNotSilentlyIgnored() throws {
    let validation = try validate(
      """
      {
        "version": 1,
        "name": "Extra setting",
        "operations": [ {
          "type": "ocr.recognize",
          "settings": {
            "pages": [ "1" ],
            "mystery": "value",
            "url": "https://example.com"
          }
        } ]
      }
      """)
    #expect(!validation.isAccepted)
    #expect(validation.errors.contains { $0.code == "unsupportedSetting" })
    #expect(validation.errors.contains { $0.code == "forbiddenKey" })
    let report = RecipePortability.compatibilityReport(validation)
    #expect(report.contains("mystery"))
  }

  @Test func declaredTypesAndRangesAreEnforced() throws {
    let outOfRange = try validate(
      """
      {
        "version": 1,
        "name": "Ranges",
        "operations": [ {
          "type": "export.presentation",
          "settings": { "destination": "a.pptx", "renderDPI": 5000 }
        } ]
      }
      """)
    #expect(!outOfRange.isAccepted)
    #expect(outOfRange.errors.contains { $0.code == "invalidSetting" })

    let wrongType = try validate(
      """
      {
        "version": 1,
        "name": "Types",
        "operations": [ {
          "type": "ocr.recognize",
          "settings": { "pages": "1-3", "level": "fastest" }
        } ]
      }
      """)
    #expect(!wrongType.isAccepted)

    let missingRequired = try validate(
      """
      { "version": 1, "name": "Missing", "operations": [ { "type": "export.docx" } ] }
      """)
    #expect(!missingRequired.isAccepted)
    #expect(missingRequired.errors.contains { $0.code == "missingSetting" })
  }

  @Test func malformedAndOversizedRecipesAreRefused() {
    #expect(throws: PDFError.self) {
      _ = try RecipePortability.validate(data: Data("not json".utf8))
    }
    #expect(throws: PDFError.self) {
      _ = try RecipePortability.validate(data: Data(repeating: 0x20, count: RecipePortability.maximumBytes + 1))
    }
    #expect(throws: PDFError.self) {
      _ = try RecipePortability.validate(data: Data())
    }
    // Deeply nested data is bounded before decoding.
    var nested = "{\"version\":1,\"name\":\"deep\",\"operations\":[],\"metadata\":{\"a\":"
    for _ in 0..<(RecipePortability.maximumSettingsDepth + 2) { nested += "[" }
    nested += "1"
    for _ in 0..<(RecipePortability.maximumSettingsDepth + 2) { nested += "]" }
    nested += "}}"
    #expect(throws: PDFError.self) {
      _ = try RecipePortability.validate(data: Data(nested.utf8))
    }
  }

  @Test func emptyRecipeWarnsButIsAccepted() throws {
    let validation = try validate(
      """
      { "version": 1, "name": "Empty", "operations": [] }
      """)
    #expect(validation.isAccepted)
    #expect(validation.warnings.contains { $0.code == "emptyRecipe" })
  }
}
