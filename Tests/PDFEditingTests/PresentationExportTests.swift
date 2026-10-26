import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// EXP-03: PowerPoint package structure, deterministic OPC parts, editable
/// text/image/shape slide objects, the labelled raster fallback and the
/// truthful editability report. The package is validated through the system
/// unzip and XML part inspection; opening it in a presentation application is
/// outside this environment.
@Suite("PowerPoint export")
struct PresentationExportTests {
  private static let pngBytes = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )!

  private func temporaryFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-exp03-\(UUID().uuidString)-\(name)")
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

  /// Extract the archive with the system unzip and read one part from disk.
  private func unzipEntry(_ archive: URL, _ path: String) throws -> Data {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-exp03-extract-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let extraction = try run(
      "/usr/bin/unzip", ["-q", "-o", archive.path, "-d", directory.path])
    #expect(
      extraction.status == 0,
      Comment(rawValue: "unzip -o \(path): " + extraction.output))
    return try Data(contentsOf: directory.appendingPathComponent(path))
  }

  private func unzipEntryText(_ archive: URL, _ path: String) throws -> String {
    String(decoding: try unzipEntry(archive, path), as: UTF8.self)
  }

  private func sampleDocument() -> PresentationExportDocument {
    let png = PresentationImageElement(
      name: "Im1", bounds: [300, 200, 500, 400], data: Self.pngBytes,
      fileExtension: "png", provenance: .renderedRegion,
      note: "Rendered region for the test.")
    let fallback = PresentationImageElement(
      name: "page-2-raster-fallback", bounds: [0, 0, 720, 540], data: Self.pngBytes,
      fileExtension: "png", provenance: .fullPageFallback,
      note: "Raster fallback: unsupported test content.")
    let slide1 = PresentationSlide(
      pageIndex: 0, size: [720, 540],
      elements: [
        .shape(
          PresentationShapeElement(
            kind: .rectangle, bounds: [40, 40, 200, 120], fillColorHex: "FF0000",
            strokeColorHex: "000000", lineWidth: 1, note: "Rectangle")),
        .shape(
          PresentationShapeElement(
            kind: .line, bounds: [10, 500, 200, 510], fillColorHex: nil,
            strokeColorHex: "0000FF", lineWidth: 2, note: "Line")),
        .image(png),
        .text(
          PresentationTextElement(
            runs: [
              PresentationTextRun(
                text: "Hello <slide> & title", fontName: "Helvetica", fontSize: 18,
                bold: true, colorHex: "112233")
            ],
            bounds: [40, 130, 400, 160], alignment: .left, rotationDegrees: 0)),
        .text(
          PresentationTextElement(
            runs: [PresentationTextRun(text: "Rotated", fontSize: 12)],
            bounds: [40, 180, 200, 210], rotationDegrees: 90)),
      ],
      notes: ["Text reconstructed from paragraph candidates."])
    let slide2 = PresentationSlide(
      pageIndex: 1, size: [720, 540], elements: [.image(fallback)],
      fallbackLabel: PresentationExportServiceLabel.text,
      notes: ["Unsupported content in the test."])
    return PresentationExportDocument(slides: [slide1, slide2], title: "Test deck")
  }

  enum PresentationExportServiceLabel {
    static let text =
      "Raster fallback: this page was not reconstructed as editable content (not editable)."
  }

  @Test func packageContainsEditableObjectsAndLabelledFallback() throws {
    let document = sampleDocument()
    let archive = try PPTXExport.package(document: document)
    let url = temporaryFile("deck.pptx")
    defer { try? FileManager.default.removeItem(at: url) }
    try archive.write(to: url)

    let listing = try run("/usr/bin/unzip", ["-l", url.path])
    #expect(listing.status == 0, Comment(rawValue: listing.output))
    for part in [
      "[Content_Types].xml", "_rels/.rels", "ppt/presentation.xml",
      "ppt/_rels/presentation.xml.rels", "ppt/slideMasters/slideMaster1.xml",
      "ppt/slideMasters/_rels/slideMaster1.xml.rels", "ppt/slideLayouts/slideLayout1.xml",
      "ppt/slideLayouts/_rels/slideLayout1.xml.rels", "ppt/theme/theme1.xml",
      "ppt/slides/slide1.xml", "ppt/slides/slide2.xml", "ppt/slides/_rels/slide1.xml.rels",
      "ppt/slides/_rels/slide2.xml.rels", "ppt/media/image0001.png",
      "ppt/media/image0002.png",
    ] {
      #expect(listing.output.contains(part), "missing part \(part)")
    }
    let test = try run("/usr/bin/unzip", ["-t", url.path])
    #expect(test.status == 0, Comment(rawValue: test.output))

    let presentation = try unzipEntryText(url, "ppt/presentation.xml")
    #expect(presentation.contains("<p:sldId id=\"256\" r:id=\"rIdSlide1\"/>"))
    #expect(presentation.contains("<p:sldId id=\"257\" r:id=\"rIdSlide2\"/>"))
    #expect(presentation.contains("cx=\"9144000\" cy=\"6858000\""))

    let slide1 = try unzipEntryText(url, "ppt/slides/slide1.xml")
    #expect(slide1.contains("Hello &lt;slide&gt; &amp; title"))
    #expect(slide1.contains("<p:pic>"))
    #expect(slide1.contains("r:embed=\"rIdImage1\""))
    #expect(slide1.contains("<p:cxnSp>"))
    #expect(slide1.contains("prst=\"line\""))
    #expect(slide1.contains("srgbClr val=\"FF0000\""))
    #expect(slide1.contains("rot=\"5400000\""))
    #expect(slide1.contains("sz=\"1800\""))
    #expect(slide1.contains("b=\"1\""))

    let slide2 = try unzipEntryText(url, "ppt/slides/slide2.xml")
    #expect(slide2.contains("Raster fallback"))
    #expect(slide2.contains("descr=\"Raster fallback:"))
    #expect(slide2.contains("this page was not reconstructed as editable content"))
    #expect(slide2.contains("<p:pic>"))

    let slide1Relationships = try unzipEntryText(url, "ppt/slides/_rels/slide1.xml.rels")
    #expect(slide1Relationships.contains("rIdImage1"))
    #expect(slide1Relationships.contains("Target=\"media/image0001.png\""))
    #expect(slide1Relationships.contains("slideLayouts/slideLayout1.xml"))

    let contentTypes = try unzipEntryText(url, "[Content_Types].xml")
    #expect(contentTypes.contains("/ppt/slides/slide1.xml"))
    #expect(contentTypes.contains("/ppt/slides/slide2.xml"))
    #expect(contentTypes.contains("image/png"))
    #expect(!contentTypes.lowercased().contains("macroenabled"))

    #expect(try unzipEntry(url, "ppt/media/image0001.png") == Self.pngBytes)

    let report = document.report
    #expect(report.slides.count == 2)
    #expect(report.slides[0].editableTextCount == 2)
    #expect(report.slides[0].editableImageCount == 1)
    #expect(report.slides[0].editableShapeCount == 2)
    #expect(!report.slides[0].rasterFallback)
    #expect(report.slides[1].rasterFallback)
    #expect(report.rasterFallbackSlideCount == 1)
    #expect(report.hasTruthfulFallbackNotes)
    let markdown = report.markdown()
    #expect(markdown.contains(PresentationEditabilityReport.truthfulnessStatement))
    #expect(markdown.contains("raster fallback: 1"))
    #expect(markdown.contains("yes (labelled, not editable)"))
    guard let data = try? report.jsonData(),
      let decoded = try? JSONDecoder().decode(
        PresentationEditabilityReport.self, from: data)
    else {
      Issue.record("The editability report must encode and decode")
      return
    }
    #expect(decoded == report)
  }

  @Test func packageIsDeterministicAndHandlesEmptyAndBounds() throws {
    let document = sampleDocument()
    #expect(try PPTXExport.package(document: document) == PPTXExport.package(document: document))

    // An empty deck still produces a valid one-slide package.
    let empty = PresentationExportDocument(slides: [], title: "Empty")
    let emptyArchive = try PPTXExport.package(document: empty)
    let url = temporaryFile("empty.pptx")
    defer { try? FileManager.default.removeItem(at: url) }
    try emptyArchive.write(to: url)
    #expect(try run("/usr/bin/unzip", ["-t", url.path]).status == 0)
    let slide = try unzipEntryText(url, "ppt/slides/slide1.xml")
    #expect(slide.contains("<p:spTree>"))
    #expect(!slide.contains("<p:pic>"))

    // The slide bound is enforced.
    let tooMany = (0..<(PPTXExport.maxSlides + 1)).map { index in
      PresentationSlide(pageIndex: index, size: [720, 540], elements: [])
    }
    #expect(throws: PDFError.self) {
      _ = try PPTXExport.package(
        document: PresentationExportDocument(slides: tooMany))
    }
  }

  @Test func sanitizedFramesKeepObjectsInsideTheSlide() throws {
    let slide = PresentationSlide(
      pageIndex: 0, size: [200, 100],
      elements: [
        .text(
          PresentationTextElement(
            runs: [PresentationTextRun(text: "Out")],
            bounds: [-50, -50, 100, 100])),
        .shape(
          PresentationShapeElement(
            kind: .rectangle, bounds: [150, 80, 500, 400],
            fillColorHex: "00FF00")),
      ])
    let archive = try PPTXExport.package(
      document: PresentationExportDocument(slides: [slide]))
    let url = temporaryFile("frames.pptx")
    defer { try? FileManager.default.removeItem(at: url) }
    try archive.write(to: url)
    let slideXML = try unzipEntryText(url, "ppt/slides/slide1.xml")
    #expect(!slideXML.contains("x=\"-"))
    #expect(!slideXML.contains("y=\"-"))
    #expect(slideXML.contains("x=\"0\" y=\"0\""))
  }
}
