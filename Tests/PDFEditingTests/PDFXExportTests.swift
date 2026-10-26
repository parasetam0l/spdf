import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// PRE-03 evidence: selected PDF/X output profiles with required boxes, embedded
/// fonts, declared output condition, identification XMP, permitted content rules
/// and self-validation of the final saved bytes.
@Suite("PDF/X export (PRE-03)")
struct PDFXExportTests {
  private func parse(_ data: Data) throws -> ParsedPDF { try PDFParser.parse(data) }

  @Test func planRefusesUnembeddedFonts() throws {
    let graph = try parse(PDFXFixture.unembeddedFontPages())
    let plan = PDFXExporter.plan(graph.graph, pageIDs: graph.pageIDs, profile: .x4)
    #expect(!plan.isExportable)
    #expect(plan.refusals.contains { $0.contains("not embedded") })
    #expect(throws: PDFError.self) {
      _ = try PDFXExporter.export(graph.graph, pageIDs: graph.pageIDs, profile: .x4)
    }
  }

  @Test func x4ExportAddsBoxesIntentIdentificationAndValidates() throws {
    let fixture = try PDFXFixture.printJobPages()
    let parsed = try parse(fixture)
    let plan = PDFXExporter.plan(parsed.graph, pageIDs: parsed.pageIDs, profile: .x4)
    #expect(plan.isExportable, Comment(rawValue: plan.summary))
    #expect(plan.transformations.contains { $0.kind == .pageBoxes })
    #expect(plan.transformations.contains { $0.kind == .outputIntent })
    #expect(plan.transformations.contains { $0.kind == .identification })
    #expect(plan.transformations.contains { $0.kind == .flattenAnnotations })
    let exported = try PDFXExporter.export(
      parsed.graph, pageIDs: parsed.pageIDs, profile: .x4)
    #expect(exported.validation.passed, Comment(rawValue: exported.validation.summary))
    let output = try parse(exported.data)
    let inventory = PDFXExporter.inventory(
      output.graph, pageIDs: output.pageIDs, profile: .x4)
    #expect(inventory.hasOutputIntent && inventory.outputIntentHasICC)
    #expect(inventory.identifiedVersion == "PDF/X-4")
    #expect(inventory.pages[0].trimBox == [18, 18, 594, 774])
    #expect(inventory.pages[0].bleedBox == [9, 9, 603, 783])
    #expect(inventory.annotationCount == 0)
    #expect(inventory.fontsNotEmbedded == 0)
    let verification = PDFXExporter.verify(data: exported.data, profile: .x4)
    #expect(verification.passed, Comment(rawValue: verification.summary))
    #expect(exported.plan.warnings.contains { $0.contains("below 150 dpi") })
  }

  @Test func x1aRefusesTransparencyAndRGBButExportsCMYKJob() throws {
    let transparent = try parse(PDFXFixture.transparencyPages())
    let transparencyPlan = PDFXExporter.plan(
      transparent.graph, pageIDs: transparent.pageIDs, profile: .x1a2003)
    #expect(!transparencyPlan.isExportable)
    #expect(transparencyPlan.refusals.contains { $0.contains("flattened transparency") })

    let rgb = try parse(PDFXFixture.rgbContentPages())
    let rgbPlan = PDFXExporter.plan(rgb.graph, pageIDs: rgb.pageIDs, profile: .x1a2003)
    #expect(!rgbPlan.isExportable)
    #expect(rgbPlan.refusals.contains { $0.contains("DeviceRGB") })

    let job = try parse(PDFXFixture.printJobPages())
    let exported = try PDFXExporter.export(
      job.graph, pageIDs: job.pageIDs, profile: .x1a2003)
    #expect(exported.validation.passed, Comment(rawValue: exported.validation.summary))
    #expect(exported.plan.profile.pdfVersion == "1.3")
  }

  @Test func x4PermitsTransparencyAndRGBContent() throws {
    let rgb = try parse(PDFXFixture.rgbContentPages())
    let plan = PDFXExporter.plan(rgb.graph, pageIDs: rgb.pageIDs, profile: .x4)
    #expect(plan.isExportable, Comment(rawValue: plan.summary))
    let exported = try PDFXExporter.export(
      rgb.graph, pageIDs: rgb.pageIDs, profile: .x4)
    #expect(exported.validation.passed, Comment(rawValue: exported.validation.summary))
  }

  @Test func savedBytesVerificationRejectsUnsavedFixture() throws {
    let fixture = try PDFXFixture.printJobPages()
    let verification = PDFXExporter.verify(data: fixture, profile: .x4)
    #expect(!verification.passed)
    #expect(verification.issues.contains { $0.contains("TrimBox") })
    #expect(verification.issues.contains { $0.contains("output intent") })
    #expect(verification.issues.contains { $0.contains("identification") })
  }

  @Test func exportNeverMutatesSourceAndDeclaresProfileLimits() throws {
    let parsed = try parse(PDFXFixture.printJobPages())
    let before = parsed.graph
    _ = try PDFXExporter.export(parsed.graph, pageIDs: parsed.pageIDs, profile: .x4)
    #expect(parsed.graph == before)
    #expect(PDFXProfile.x4.declaredLimits.contains("not a colorimetric"))
    #expect(PDFXProfile.x1a2003.declaredLimits.contains("PRE-05"))
    #expect(PDFXICCProfile.declaredCMYK().count > 132)
  }
@Test func writesIndependentValidationArtifactsWhenRequested() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["SPDF_PRE_ARTIFACTS"] == "1" else { return }
    let directory = URL(
      fileURLWithPath: environment["SPDF_PRE_ARTIFACT_DIR"] ?? "/tmp/spdf-pre-artifacts")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let parsed = try parse(PDFXFixture.printJobPages())
    let x4 = try PDFXExporter.export(
      parsed.graph, pageIDs: parsed.pageIDs, profile: .x4)
    try x4.data.write(to: directory.appendingPathComponent("print-job-x4.pdf"))
    let x1a = try PDFXExporter.export(
      parsed.graph, pageIDs: parsed.pageIDs, profile: .x1a2003)
    try x1a.data.write(to: directory.appendingPathComponent("print-job-x1a.pdf"))
    var session = PreflightFixupSession(
      graph: parsed.graph, pageIDs: parsed.pageIDs, ruleSet: .pdfx4, profile: .x4)
    for fixup in [
      PreflightFixup.addTrimBoxes, .addOutputIntent, .addPDFXIdentification,
      .flattenAnnotations,
    ] {
      _ = try session.apply(fixup)
    }
    let fixed = try PDFWriter.write(session.graph)
    try fixed.write(to: directory.appendingPathComponent("print-job-preflight-fixed.pdf"))
    try session.exportReport().write(
      to: directory.appendingPathComponent("preflight-report.txt"),
      atomically: true, encoding: .utf8)
  }
}
