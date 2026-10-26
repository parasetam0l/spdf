import Foundation
import MacServices
import PDFCore
import PDFEditing
import PDFFixtures
import Testing

/// EXP-03: the host-side service that turns the page reconstruction plan into
/// a PowerPoint package, with a labelled raster fallback for pages that cannot
/// be reconstructed and a truthful editability report.
@Suite("Presentation export service")
struct PresentationExportServiceTests {
  private func temporaryFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-exp03-service-\(UUID().uuidString)-\(name)")
  }

  private func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String)
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    return (
      process.terminationStatus,
      String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    )
  }

  private func unzipEntry(_ archive: URL, _ path: String) throws -> Data {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-exp03-service-extract-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let extraction = try run(
      "/usr/bin/unzip", ["-q", "-o", archive.path, "-d", directory.path])
    #expect(extraction.status == 0, Comment(rawValue: extraction.output))
    return try Data(contentsOf: directory.appendingPathComponent(path))
  }

  private func unzipEntryText(_ archive: URL, _ path: String) throws -> String {
    String(decoding: try unzipEntry(archive, path), as: UTF8.self)
  }

  private func document(
    from data: Data, options: PresentationExportOptions = .init()
  ) throws -> (document: PresentationExportDocument, archive: URL) {
    let parsed = try PDFParser.parse(data)
    let document = try PresentationExportService.reconstruct(
      pageIDs: parsed.pageIDs, in: parsed.graph, title: "Test export", options: options)
    let archive = temporaryFile("deck.pptx")
    try PresentationExportService.write(document, to: archive)
    return (document, archive)
  }

  @Test func textDocumentExportsEditableTextBoxes() throws {
    let result = try document(from: try PDFFixtures.textEditPages())
    defer { try? FileManager.default.removeItem(at: result.archive) }
    #expect(result.document.slides.count == 1)
    let slide = result.document.slides[0]
    #expect(!slide.hasRasterFallback)
    #expect(slide.editableTextCount > 0)
    #expect(slide.fallbackLabel == nil)
    #expect(result.document.report.rasterFallbackSlideCount == 0)
    #expect(result.document.report.editableElementCount > 0)
    #expect(result.document.report.hasTruthfulFallbackNotes)

    #expect(try run("/usr/bin/unzip", ["-t", result.archive.path]).status == 0)
    let slideXML = try unzipEntryText(result.archive, "ppt/slides/slide1.xml")
    #expect(slideXML.contains("<a:t>"))
    #expect(slideXML.contains("<p:sp>"))
    #expect(!slideXML.contains("Raster fallback"))
    let presentation = try unzipEntryText(result.archive, "ppt/presentation.xml")
    #expect(presentation.contains("<p:sldSz cx=\"7772400\" cy=\"10058400\""))
  }

  @Test func imageDocumentExportsEditablePictures() throws {
    let result = try document(from: try PDFFixtures.imagePages())
    defer { try? FileManager.default.removeItem(at: result.archive) }
    let slide = result.document.slides[0]
    #expect(!slide.hasRasterFallback)
    #expect(slide.editableImageCount > 0)
    let listing = try run("/usr/bin/unzip", ["-l", result.archive.path])
    #expect(listing.output.contains("ppt/media/"))
    let slideXML = try unzipEntryText(result.archive, "ppt/slides/slide1.xml")
    #expect(slideXML.contains("<p:pic>"))
    #expect(slideXML.contains("r:embed=\"rIdImage1\""))
    let report = result.document.report
    #expect(report.slides[0].editableImageCount == slide.editableImageCount)
  }

  @Test func unsupportedPageBecomesLabelledRasterFallback() throws {
    let result = try document(from: try PDFFixtures.formXObjectPages())
    defer { try? FileManager.default.removeItem(at: result.archive) }
    let slide = result.document.slides[0]
    #expect(slide.hasRasterFallback)
    #expect(slide.editableTextCount == 0)
    #expect(slide.editableImageCount == 0)
    #expect(slide.fallbackLabel?.contains("Raster fallback") == true)
    let report = result.document.report
    // The fixture has two pages; both cannot be reconstructed as editable content.
    #expect(report.rasterFallbackSlideCount == result.document.slides.count)
    #expect(report.hasTruthfulFallbackNotes)
    let markdown = report.markdown()
    #expect(markdown.contains("not editable"))
    #expect(markdown.contains("Raster fallback"))

    let slideXML = try unzipEntryText(result.archive, "ppt/slides/slide1.xml")
    #expect(slideXML.contains("Raster fallback"))
    let listing = try run("/usr/bin/unzip", ["-l", result.archive.path])
    #expect(listing.output.contains("ppt/media/image0001.png"))
    let media = try unzipEntry(result.archive, "ppt/media/image0001.png")
    #expect(media.starts(with: [0x89, 0x50, 0x4E, 0x47]), "the fallback is a rendered PNG")
  }

  @Test func fallbackLabelCanBeDisabledButReportStaysTruthful() throws {
    var options = PresentationExportOptions()
    options.includeFallbackLabel = false
    let result = try document(from: try PDFFixtures.formXObjectPages(), options: options)
    defer { try? FileManager.default.removeItem(at: result.archive) }
    let slide = result.document.slides[0]
    #expect(slide.hasRasterFallback)
    #expect(slide.fallbackLabel == nil)
    #expect(
      result.document.report.rasterFallbackSlideCount == result.document.slides.count)
    #expect(result.document.report.markdown().contains("not editable"))
  }

  @Test func optionsAreBounded() {
    let options = PresentationExportOptions(renderDPI: 5_000, maxPages: 0)
    #expect(options.renderDPI == 600)
    #expect(options.maxPages == 1)
  }

  @Test func pageSizeMapsToSlideGeometry() throws {
    let parsed = try PDFParser.parse(try PDFFixtures.textEditPages())
    let document = try PresentationExportService.reconstruct(
      pageIDs: Array(parsed.pageIDs.prefix(1)), in: parsed.graph, title: "Geometry")
    let slide = document.slides[0]
    #expect(slide.size == [612, 792])
    let archive = temporaryFile("geometry.pptx")
    defer { try? FileManager.default.removeItem(at: archive) }
    try PresentationExportService.write(document, to: archive)
    let presentation = try unzipEntryText(archive, "ppt/presentation.xml")
    // 612 x 792 points in EMU.
    #expect(presentation.contains("cx=\"7772400\" cy=\"10058400\""))
  }
}
