import AppKit
import CoreGraphics
import Foundation
import PDFCore
import PDFEditing
@testable import MacServices
import Testing

@Suite("Advanced print export")
@MainActor
struct AdvancedPrintExportTests {
  // MARK: Fixtures

  private func pageGraph(
    pages: [(size: [Double], content: String, annotations: [PDFValue]?)] = [],
    resources: [[PDFName: PDFValue]]? = nil,
    extraObjects: [PDFObjectID: PDFValue] = [:]
  ) -> PDFGraph {
    let pageIDs = (0..<pages.count).map { PDFObjectID(4 + $0 * 2) }
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(Int64(pages.count)),
        PDFName("Kids"): .array(pageIDs.map(PDFValue.reference)),
      ]),
    ]
    for (index, page) in pages.enumerated() {
      let pageID = pageIDs[index]
      let contentID = PDFObjectID(pageID.number + 1)
      objects[contentID] = .stream(PDFStream(bytes: Data(page.content.utf8)))
      var dictionary: [PDFName: PDFValue] = [
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .real(page.size[0]), .real(page.size[1]),
        ]),
        PDFName("Resources"): .dictionary(resources?[index] ?? [:]),
        PDFName("Contents"): .reference(contentID),
      ]
      if let annotations = page.annotations, !annotations.isEmpty {
        dictionary[PDFName("Annots")] = .array(annotations)
      }
      objects[pageID] = .dictionary(dictionary)
    }
    for (id, value) in extraObjects { objects[id] = value }
    return PDFGraph(objects: objects, trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  private func solidPages(_ colors: [(Double, Double, Double)], size: [Double] = [612, 792])
    -> PDFGraph
  {
    let mapped = colors.map { color in
      (
        size: size,
        content: String(
          format: "%.3f %.3f %.3f rg 0 0 %.3f %.3f re f",
          color.0, color.1, color.2, size[0], size[1]),
        annotations: nil as [PDFValue]?
      )
    }
    return pageGraph(pages: mapped)
  }

  private func writeTemporary(_ data: Data, name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-advanced-print-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try data.write(to: url)
    return url
  }

  private func graphData(_ graph: PDFGraph) throws -> Data {
    try PDFWriter.write(graph)
  }

  // MARK: Independent rendering

  struct PixelImage {
    let width: Int
    let height: Int
    let bytes: [UInt8]
    let bytesPerRow: Int
    /// True when raw row 0 is the top of the image.
    let rowZeroIsTop: Bool

    func pixel(xNormalized: Double, yNormalizedFromBottom: Double) -> (r: Double, g: Double, b: Double)? {
      let x = min(max(Int(xNormalized * Double(width)), 0), width - 1)
      var yFromTop = 1 - yNormalizedFromBottom
      if !rowZeroIsTop { yFromTop = 1 - yFromTop }
      let y = min(max(Int(yFromTop * Double(height)), 0), height - 1)
      let offset = y * bytesPerRow + x * 4
      guard offset + 3 < bytes.count else { return nil }
      return (
        Double(bytes[offset]) / 255, Double(bytes[offset + 1]) / 255,
        Double(bytes[offset + 2]) / 255)
    }
  }

  private func popplerPath() -> String? {
    for path in ["/opt/homebrew/bin/pdftoppm", "/usr/local/bin/pdftoppm"] where
      FileManager.default.isExecutableFile(atPath: path)
    {
      return path
    }
    return nil
  }

  /// Render one page through poppler (independent of our print pipeline).
  private func popplerPNG(pdfURL: URL, page: Int, dpi: Int = 72) throws -> PixelImage? {
    guard let tool = popplerPath() else { return nil }
    let prefix = pdfURL.deletingLastPathComponent()
      .appendingPathComponent("render-" + UUID().uuidString)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = [
      "-png", "-r", String(dpi), "-f", String(page), "-l", String(page),
      pdfURL.path, prefix.path,
    ]
    process.standardError = Pipe()
    process.standardOutput = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let digits = max(3, String(page).count)
    let padded = String(format: "%0\(digits)d", page)
    let candidates = [
      URL(fileURLWithPath: prefix.path + "-" + padded + ".png"),
      URL(fileURLWithPath: prefix.path + "-" + String(page) + ".png"),
    ]
    guard let png = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
      let data = try? Data(contentsOf: png)
    else { return nil }
    return decodePNG(data)
  }

  private func decodePNG(_ data: Data) -> PixelImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
    guard let context = CGContext(
      data: &bytes, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    // Empirically (and cross-checked against the annotation fixture) the
    // decoded bitmap keeps the image's top row at memory row 0.
    return PixelImage(
      width: width, height: height, bytes: bytes, bytesPerRow: bytesPerRow,
      rowZeroIsTop: true)
  }

  private func sampleColor(
    _ image: PixelImage, targetPDFRect: [Double], pageWidth: Double, pageHeight: Double
  ) -> (r: Double, g: Double, b: Double)? {
    guard targetPDFRect.count == 4 else { return nil }
    let xNorm = (targetPDFRect[0] + targetPDFRect[2] / 2) / pageWidth
    let yNorm = (targetPDFRect[1] + targetPDFRect[3] / 2) / pageHeight
    return image.pixel(xNormalized: xNorm, yNormalizedFromBottom: yNorm)
  }

  private func assertColorMatches(
    _ actual: (r: Double, g: Double, b: Double)?, _ expected: (Double, Double, Double),
    tolerance: Double = 0.15, _ message: String
  ) {
    guard let actual else {
      Issue.record(Comment(rawValue: "No rendered pixel for " + message))
      return
    }
    let difference = max(
      abs(actual.r - expected.0), abs(actual.g - expected.1), abs(actual.b - expected.2))
    #expect(
      difference <= tolerance,
      Comment(rawValue: message + " got " + String(describing: actual)))
  }

  // MARK: N-up

  @Test func nUpPageOrderMatchesPlanAgainstIndependentRenders() throws {
    guard popplerPath() != nil else { return }
    let colors: [(Double, Double, Double)] = [
      (1, 0, 0), (0, 0.7, 0), (0, 0, 1), (1, 1, 0),
    ]
    let graph = solidPages(colors)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let sourceURL = try writeTemporary(try graphData(graph), name: "source.pdf")
    let options = PDFAdvancedPrintOptions(
      layout: .nUp(rows: 2, columns: 2), scale: .fit, paperSize: [612, 792],
      margin: 18, gutter: 12)
    let (data, report) = try PDFAdvancedPrintExport.pdfData(
      pageIDs: pageIDs, in: graph, options: options)
    #expect(report.outputPageCount == 1)
    #expect(report.plan.sides[0].placements.map(\.sourcePageIndex) == [0, 1, 2, 3])
    let outputURL = try writeTemporary(data, name: "nup.pdf")
    let output = try #require(try popplerPNG(pdfURL: outputURL, page: 1))
    let side = report.plan.sides[0]
    let pageWidth = side.paperSize[0]
    let pageHeight = side.paperSize[1]
    for placement in side.placements {
      let source = try #require(try popplerPNG(pdfURL: sourceURL, page: placement.sourcePageIndex + 1))
      let expected = try #require(source.pixel(xNormalized: 0.5, yNormalizedFromBottom: 0.5))
      let actual = sampleColor(
        output, targetPDFRect: placement.targetRect, pageWidth: pageWidth, pageHeight: pageHeight)
      assertColorMatches(
        actual, (expected.r, expected.g, expected.b),
        "N-up cell for page " + String(placement.sourcePageIndex + 1))
    }
  }

  // MARK: Booklet

  @Test func bookletOrderMatchesPlanAgainstIndependentRenders() throws {
    guard popplerPath() != nil else { return }
    let colors: [(Double, Double, Double)] = [
      (1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0),
      (1, 0, 1), (0, 1, 1), (0.5, 0.5, 0.5), (0.2, 0.4, 0.9),
    ]
    let graph = solidPages(colors)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let sourceURL = try writeTemporary(try graphData(graph), name: "booklet-source.pdf")
    let options = PDFAdvancedPrintOptions(layout: .booklet, scale: .fit)
    let (data, report) = try PDFAdvancedPrintExport.pdfData(
      pageIDs: pageIDs, in: graph, options: options)
    #expect(report.outputPageCount == 4)
    #expect(report.plan.sides[0].placements.map(\.sourcePageIndex) == [7, 0])
    let outputURL = try writeTemporary(data, name: "booklet.pdf")
    for side in report.plan.sides {
      let output = try #require(
        try popplerPNG(pdfURL: outputURL, page: side.sideIndex + 1))
      for placement in side.placements {
        let source = try #require(
          try popplerPNG(pdfURL: sourceURL, page: placement.sourcePageIndex + 1))
        let expected = try #require(source.pixel(xNormalized: 0.5, yNormalizedFromBottom: 0.5))
        let actual = sampleColor(
          output, targetPDFRect: placement.targetRect,
          pageWidth: side.paperSize[0], pageHeight: side.paperSize[1])
        assertColorMatches(
          actual, (expected.r, expected.g, expected.b),
          "Booklet side " + String(side.sideIndex + 1) + " page "
            + String(placement.sourcePageIndex + 1))
      }
    }
  }

  // MARK: Poster

  @Test func posterTilesMatchIndependentCropsAndOutputSizes() throws {
    guard popplerPath() != nil else { return }
    let content = """
      1 0 0 rg 0 396 306 396 re f
      0 1 0 rg 306 396 306 396 re f
      0 0 1 rg 0 0 306 396 re f
      1 1 0 rg 306 0 306 396 re f
      """
    let graph = pageGraph(pages: [(size: [612, 792], content: content, annotations: nil)])
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let options = PDFAdvancedPrintOptions(
      layout: .poster(rows: 2, columns: 2, overlap: 0), scale: .actual, margin: 10)
    let (data, report) = try PDFAdvancedPrintExport.pdfData(
      pageIDs: pageIDs, in: graph, options: options)
    #expect(report.outputPageCount == 4)
    let outputURL = try writeTemporary(data, name: "poster.pdf")
    let parsed = try PDFParser.parse(try Data(contentsOf: outputURL))
    #expect(parsed.pageIDs.count == 4)
    for (index, pageID) in parsed.pageIDs.enumerated() {
      let mediaBox = try #require(parsed.graph.objects[pageID].flatMap { value -> [Double]? in
        guard case .dictionary(let dictionary) = value,
          case .array(let values)? = dictionary[PDFName("MediaBox")]
        else { return nil }
        return values.compactMap { value -> Double? in
          switch value {
          case .integer(let number): return Double(number)
          case .real(let number): return number
          default: return nil
          }
        }
      })
      #expect(abs(mediaBox[2] - 326) < 1.0)
      #expect(abs(mediaBox[3] - 416) < 1.0)
      _ = index
    }
    let expected: [(Double, Double, Double)] = [
      (1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0),
    ]
    for (index, side) in report.plan.sides.enumerated() {
      let output = try #require(try popplerPNG(pdfURL: outputURL, page: index + 1))
      let placement = try #require(side.placements.first)
      let actual = sampleColor(
        output, targetPDFRect: placement.clipRect ?? placement.targetRect,
        pageWidth: 326, pageHeight: 416)
      assertColorMatches(actual, expected[index], "Poster tile " + String(index + 1))
    }
  }

  // MARK: Comments

  @Test func commentsToggleChangesRenderedAnnotationAppearance() throws {
    guard popplerPath() != nil else { return }
    let annotationID = PDFObjectID(10)
    let appearanceID = PDFObjectID(11)
    let appearance = PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Form")),
        PDFName("BBox"): .array([.integer(0), .integer(0), .integer(150), .integer(150)]),
        PDFName("Resources"): .dictionary([:]),
      ], bytes: Data("1 0 0 rg 0 0 150 150 re f".utf8))
    let annotation = PDFValue.dictionary([
      PDFName("Type"): .name(PDFName("Annot")),
      PDFName("Subtype"): .name(PDFName("Square")),
      PDFName("Rect"): .array([.real(100), .real(500), .real(250), .real(650)]),
      PDFName("F"): .integer(4),
      PDFName("C"): .array([.real(1), .real(0), .real(0)]),
      PDFName("AP"): .dictionary([PDFName("N"): .reference(appearanceID)]),
    ])
    let graph = pageGraph(
      pages: [(
        size: [612, 792],
        content: "1 1 1 rg 0 0 612 792 re f",
        annotations: [.reference(annotationID)]
      )],
      extraObjects: [
        annotationID: annotation,
        appearanceID: .stream(appearance),
      ])
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let sourceURL = try writeTemporary(try graphData(graph), name: "comments-source.pdf")
    let sourceImage = try #require(try popplerPNG(pdfURL: sourceURL, page: 1))
    let independentAnnotation = try #require(
      sourceImage.pixel(xNormalized: 175.0 / 612.0, yNormalizedFromBottom: 575.0 / 792.0))
    // Poppler renders the annotation appearance; this is the independent reference.

    func export(includeComments: Bool) throws -> PixelImage {
      let options = PDFAdvancedPrintOptions(
        layout: .single, scale: .actual, paperSize: [612, 792], margin: 0,
        includeComments: includeComments)
      let (data, _) = try PDFAdvancedPrintExport.pdfData(
        pageIDs: pageIDs, in: graph, options: options)
      let url = try writeTemporary(data, name: "comments-" + String(includeComments) + ".pdf")
      return try #require(try popplerPNG(pdfURL: url, page: 1))
    }
    let without = try export(includeComments: false)
    let with = try export(includeComments: true)
    let annotationPoint = (x: 175.0 / 612.0, y: 575.0 / 792.0)
    let withoutPixel = try #require(
      without.pixel(xNormalized: annotationPoint.x, yNormalizedFromBottom: annotationPoint.y))
    let withPixel = try #require(
      with.pixel(xNormalized: annotationPoint.x, yNormalizedFromBottom: annotationPoint.y))
    #expect(max(withoutPixel.r, withoutPixel.g, withoutPixel.b) > 0.9)
    #expect(withPixel.r > 0.8 && withPixel.g < 0.2 && withPixel.b < 0.2)
    assertColorMatches(
      (withPixel.r, withPixel.g, withPixel.b),
      (independentAnnotation.r, independentAnnotation.g, independentAnnotation.b),
      tolerance: 0.15, "Comment appearance should match the independent annotation render")
  }

  // MARK: Mixed sizes

  @Test func mixedPageSizesArePreservedInSingleLayout() throws {
    let graph = pageGraph(pages: [
      (size: [612, 792], content: "1 0 0 rg 0 0 612 792 re f", annotations: nil),
      (size: [595, 842], content: "0 1 0 rg 0 0 595 842 re f", annotations: nil),
    ])
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    var options = PDFAdvancedPrintOptions(layout: .single, scale: .fit)
    options.mixedPageSizes = true
    let (data, report) = try PDFAdvancedPrintExport.pdfData(
      pageIDs: pageIDs, in: graph, options: options)
    #expect(report.outputPageCount == 2)
    #expect(abs(report.plan.sides[0].paperSize[0] - 648) < 0.1)
    #expect(abs(report.plan.sides[1].paperSize[1] - 878) < 0.1)
    let parsed = try PDFParser.parse(data)
    #expect(parsed.pageIDs.count == 2)
    let boxes = try parsed.pageIDs.map { pageID -> [Double] in
      guard case .dictionary(let dictionary)? = parsed.graph.objects[pageID],
        case .array(let values)? = dictionary[PDFName("MediaBox")]
      else { return [] }
      return values.compactMap { value -> Double? in
        switch value {
        case .integer(let number): return Double(number)
        case .real(let number): return number
        default: return nil
        }
      }
    }
    #expect(abs((boxes[0][2]) - 648) < 1.0)
    #expect(abs((boxes[1][3]) - 878) < 1.0)
  }

  // MARK: Flattening preview

  @Test func flatteningPreviewMatchesIndependentRenderAndDisclosesLimits() throws {
    guard popplerPath() != nil else { return }
    let stateID = PDFObjectID(9)
    let content = """
      1 0 0 rg 100 100 300 300 re f
      0 0 1 rg 250 250 300 300 re f
      """
    let graph = pageGraph(
      pages: [(size: [612, 792], content: content, annotations: nil)],
      resources: [[
        PDFName("ExtGState"): .dictionary([PDFName("GS1"): .reference(stateID)])
      ]],
      extraObjects: [
        stateID: .dictionary([
          PDFName("Type"): .name(PDFName("ExtGState")),
          PDFName("ca"): .real(0.5),
          PDFName("CA"): .real(0.5),
        ])
      ])
    // The fixture above draws opaque squares; add transparency using the state.
    let transparentGraph = pageGraph(
      pages: [(
        size: [612, 792],
        content: "/GS1 gs 1 0 0 rg 100 100 300 300 re f 0 0 1 rg 250 250 300 300 re f",
        annotations: nil
      )],
      resources: [[
        PDFName("ExtGState"): .dictionary([PDFName("GS1"): .reference(stateID)])
      ]],
      extraObjects: [
        stateID: .dictionary([
          PDFName("Type"): .name(PDFName("ExtGState")),
          PDFName("ca"): .real(0.5),
          PDFName("CA"): .real(0.5),
        ])
      ])
    _ = graph
    let pageIDs = try PDFPageTree.pageIDs(in: transparentGraph)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-preview-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let report = try PDFPrintPreviewExport.writePNGPreviews(
      pageIDs: pageIDs, in: transparentGraph, to: directory, dpi: 72)
    #expect(report.pageCount == 1)
    #expect(report.transparencyUses > 0)
    #expect(report.disclosure.contains("not a production flattener"))
    #expect(report.warnings.contains { $0.contains("not simulated") })
    let previewURL = directory.appendingPathComponent(try #require(report.files.first))
    let previewImage = try #require(try decodePNG(Data(contentsOf: previewURL)))
    let sourceURL = try writeTemporary(try graphData(transparentGraph), name: "preview-source.pdf")
    let sourceImage = try #require(try popplerPNG(pdfURL: sourceURL, page: 1))
    let point = (x: 325.0 / 612.0, y: 325.0 / 792.0)
    let previewPixel = try #require(
      previewImage.pixel(xNormalized: point.x, yNormalizedFromBottom: point.y))
    let sourcePixel = try #require(
      sourceImage.pixel(xNormalized: point.x, yNormalizedFromBottom: point.y))
    assertColorMatches(
      (previewPixel.r, previewPixel.g, previewPixel.b),
      (sourcePixel.r, sourcePixel.g, sourcePixel.b), tolerance: 0.08,
      "Flattening preview should match the independent renderer for the claimed profile")
  }

  // MARK: Production marks

  @Test func productionMarksPDFHasOutputSizeCropMarksAndContent() throws {
    guard popplerPath() != nil else { return }
    let graph = pageGraph(pages: [
      (size: [612, 792], content: "0 0 1 rg 24 24 612 792 re f", annotations: nil)
    ])
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let layout = try ProductionMarksPlanner.plan(
      pageInputs: [ProductionMarksPageInput(mediaBox: [0, 0, 612, 792])],
      options: ProductionMarksOptions(
        margin: 24, cropMarkLength: 12, markGap: 3, jobLabel: "Press proof",
        inks: [ProductionInk(name: "Cyan", isProcess: true),
          ProductionInk(name: "PANTONE 185 C")])) 
    let (data, exportedLayout) = try PDFProductionMarksExport.pdfData(
      pageIDs: pageIDs, in: graph,
      options: ProductionMarksOptions(
        margin: 24, cropMarkLength: 12, markGap: 3, jobLabel: "Press proof",
        inks: [ProductionInk(name: "Cyan", isProcess: true),
          ProductionInk(name: "PANTONE 185 C")]))
    #expect(exportedLayout.pages[0].outputBox == layout.pages[0].outputBox)
    let outputURL = try writeTemporary(data, name: "marks.pdf")
    guard let provider = CGDataProvider(data: data as CFData),
      let document = CGPDFDocument(provider),
      let page = document.page(at: 1)
    else {
      Issue.record("Marks output is unreadable by CoreGraphics")
      return
    }
    #expect(document.numberOfPages == 1)
    let box = page.getBoxRect(.mediaBox)
    #expect(abs(box.width - 660) < 1.0)
    #expect(abs(box.height - 840) < 1.0)
    let output = try #require(try popplerPNG(pdfURL: outputURL, page: 1))
    // Crop mark at the left of the trim box (output x ~ 9..21, y = 24).
    let mark = try #require(
      output.pixel(xNormalized: 15.0 / 660.0, yNormalizedFromBottom: 24.0 / 840.0))
    #expect(max(mark.r, mark.g, mark.b) < 0.5)
    // Source content centre remains the intended blue.
    let content = try #require(
      output.pixel(xNormalized: 330.0 / 660.0, yNormalizedFromBottom: 420.0 / 840.0))
    #expect(content.b > 0.7 && content.r < 0.3 && content.g < 0.3)
  }
}
