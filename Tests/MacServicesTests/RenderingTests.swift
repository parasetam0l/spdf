import CoreGraphics
import Foundation
import MacServices
import PDFCore
import PDFEditing
import PDFFixtures
import PDFKit
import Testing

@Suite("Apple interoperability")
struct RenderingTests {
  @Test func coreOutputOpensAndContainsExpectedTextInPDFKit() throws {
    let fixture = try PDFFixtures.threePages()
    let document = try #require(PDFDocument(data: fixture))
    #expect(document.pageCount == 3)
    #expect(document.page(at: 2)?.rotation == 90)
    #expect(document.string?.contains("sPDF Editor fixture - page 1") == true)
    #expect(document.string?.contains("sPDF Editor fixture - page 3") == true)
  }

  /// Apple's PDFKit is an implementation independent of our parser; it must
  /// accept the generated cross-reference/object-stream fixture.
  @Test func xrefStreamFixtureOpensInPDFKit() throws {
    let fixture = try PDFFixtures.xrefStreamPages()
    let document = try #require(PDFDocument(data: fixture))
    #expect(document.pageCount == 2)
    #expect(document.string?.contains("sPDF Editor xref-stream fixture - page 1") == true)
    #expect(document.string?.contains("sPDF Editor xref-stream fixture - page 2") == true)
  }

  /// P23-005 verification: an owned-core rotation edit is visible to an
  /// independent renderer after the edited bytes are written.
  @Test func editedPageRotationIsVisibleToPDFKit() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([RotatePagesCommand(pageIDs: parsed.pageIDs, byDegrees: 90)]),
      to: parsed.graph)
    let edited = try PDFWriter.write(graph)
    let document = try #require(PDFDocument(data: edited))
    #expect(document.pageCount == 1)
    #expect(document.page(at: 0)?.rotation == 90)
    #expect(document.string?.contains("sPDF Editor fixture - page 1") == true)
  }

  @Test func hybridAndIncrementalFixturesOpenInPDFKit() throws {
    let hybridDocument = try #require(PDFDocument(data: PDFFixtures.hybridReferencePages()))
    #expect(hybridDocument.pageCount == 1)
    #expect(hybridDocument.string?.contains("hybrid-reference fixture - page 1") == true)

    let incrementalDocument = try #require(PDFDocument(data: PDFFixtures.incrementalUpdate()))
    #expect(incrementalDocument.pageCount == 1)
    #expect(incrementalDocument.string?.contains("updated revision") == true)
    #expect(incrementalDocument.string?.contains("base revision") != true)
  }

  /// P09-019 verification: an incremental append stays readable in an
  /// independent implementation and shows the new revision.
  @Test func incrementalSaveOutputOpensInPDFKit() throws {
    let original = try PDFFixtures.onePage()
    let parsed = try PDFParser.parse(original)
    var updated = parsed.graph
    guard case .dictionary(var page)? = updated.objects[parsed.pageIDs[0]] else {
      Issue.record("Page missing")
      return
    }
    page[PDFName("Rotate")] = .integer(90)
    updated.objects[parsed.pageIDs[0]] = .dictionary(page)
    let data = try PDFWriter.incrementalUpdate(from: parsed, to: updated)
    let document = try #require(PDFDocument(data: data))
    #expect(document.pageCount == 1)
    #expect(document.page(at: 0)?.rotation == 90)
  }

  /// P18-025/P18-026 verification: replacement text extracts in an
  /// independent reader and the original text is gone.
  @Test func editedTextIsVisibleToPDFKit() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textEditPages())
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextCommand(
          pageID: parsed.pageIDs[0], runIndex: 0, replacement: "Edited in PDFKit check")
      ]), to: parsed.graph)
    let data = try PDFWriter.write(graph)
    let document = try #require(PDFDocument(data: data))
    #expect(document.string?.contains("Edited in PDFKit check") == true)
    #expect(document.string?.contains("Replace this text") != true)
    #expect(document.string?.contains("Quotes (kept)") == true)
  }

  /// P18-009 verification: a compensated TJ edit extracts correctly in an
  /// independent reader.
  @Test func widthAwareTjEditsExtractInPDFKit() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextCommand(pageID: parsed.pageIDs[0], runIndex: 0, replacement: "A")
      ]), to: parsed.graph)
    let document = try #require(PDFDocument(data: PDFWriter.write(graph)))
    let text = document.string ?? ""
    #expect(text.contains("CD"))
    #expect(!text.contains("AB"))
    #expect(text.filter { !$0.isWhitespace } == "ACD")
  }

  /// P20-004/007 verification: moved and replaced image instances render
  /// with the expected pixels in an independent renderer.
  @Test func movedAndReplacedImageRendersInCoreGraphics() throws {
    let original = try PDFFixtures.imagePages()
    let green = try Self.pixel(of: original, page: 1, at: CGPoint(x: 140, y: 660))
    #expect(green.g > 200 && green.r < 60 && green.b < 60)

    let parsed = try PDFParser.parse(original)
    let pageID = parsed.pageIDs[0]
    var graph = try PDFEditingEngine.commit(
      PDFTransaction([MoveImageCommand(pageID: pageID, placementIndex: 0, dx: 40, dy: -25)]),
      to: parsed.graph)
    let magenta = Data([255, 0, 255, 255, 0, 255, 255, 0, 255, 255, 0, 255])
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceImageDataCommand(
          pageID: pageID, placementIndex: 0, width: 2, height: 2, rgb8: magenta)
      ]), to: graph)
    let edited = try PDFWriter.write(graph)

    let moved = try Self.pixel(of: edited, page: 1, at: CGPoint(x: 180, y: 635))
    #expect(moved.r > 200 && moved.b > 200 && moved.g < 60)
    let vacated = try Self.pixel(of: edited, page: 1, at: CGPoint(x: 90, y: 610))
    #expect(vacated.r > 240 && vacated.g > 240 && vacated.b > 240)
    let second = try Self.pixel(of: edited, page: 1, at: CGPoint(x: 140, y: 460))
    #expect(second.g > 200 && second.r < 60 && second.b < 60)
  }

  /// P20-006 verification: a 90-degree placement rotation moves the rendered
  /// image exactly, and the vacated area returns to the page background.
  @Test func rotatedImageRendersInCoreGraphics() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let pageID = parsed.pageIDs[0]
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([RotateImageCommand(pageID: pageID, placementIndex: 0, degrees: 90)]),
      to: parsed.graph)
    let edited = try PDFWriter.write(graph)
    let inside = try Self.pixel(of: edited, page: 1, at: CGPoint(x: 40, y: 660))
    #expect(inside.g > 200 && inside.r < 60 && inside.b < 60)
    let background = try Self.pixel(of: edited, page: 1, at: CGPoint(x: 300, y: 300))
    #expect(background.r > 240 && background.g > 240 && background.b > 240)
  }

  private static func pixel(of data: Data, page: Int, at point: CGPoint) throws -> (
    r: Int, g: Int, b: Int
  ) {
    let provider = try #require(CGDataProvider(data: data as CFData))
    let document = try #require(CGPDFDocument(provider))
    let pdfPage = try #require(document.page(at: page))
    let box = pdfPage.getBoxRect(.mediaBox)
    let width = Int(box.width.rounded())
    let height = Int(box.height.rounded())
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: box.width, height: box.height))
    context.drawPDFPage(pdfPage)
    let image = try #require(context.makeImage())
    let raw = try #require(image.dataProvider?.data)
    let bytes = CFDataGetBytePtr(raw)!
    let x = Int(point.x)
    let y = Int(point.y)
    let offset = ((height - 1 - y) * width + x) * 4
    return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
  }

  /// P22-002 interoperability: Apple's reader sees the owned highlight, its
  /// quads, and renders the generated appearance stream without synthesizing
  /// one of its own.
  @Test func appleReadsAndRendersOwnedHighlight() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let layout = try PageTextLayout.build(pageID: pageID, in: parsed.graph)
    let word = try #require(layout.words.first)
    let clusterBounds = layout.clusters[word].map(\.bounds)
    let quads = AddHighlightCommand.quads(forClusterBounds: clusterBounds)
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([AddHighlightCommand(pageID: pageID, quads: quads, contents: "Reviewed")]),
      to: parsed.graph)
    let document = try #require(PDFDocument(data: try PDFWriter.write(graph)))
    let page = try #require(document.page(at: 0))
    #expect(page.annotations.count == 1)
    let annotation = try #require(page.annotations.first)
    #expect(annotation.type == "Highlight")
    #expect(annotation.contents == "Reviewed")
    #expect(abs(annotation.bounds.minX - 42) < 0.5)
    #expect(abs(annotation.bounds.maxX - 62) < 0.5)
    #expect(abs(annotation.bounds.minY - 710) < 0.5)
    #expect(abs(annotation.bounds.maxY - 730) < 0.5)

    let image = page.thumbnail(of: NSSize(width: 612, height: 792), for: .mediaBox)
    let tiff = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiff))
    let pixel = try #require(
      bitmap.colorAt(x: 52, y: 792 - 720)?.usingColorSpace(.deviceRGB))
    #expect(pixel.redComponent > 0.9 && pixel.blueComponent < 0.9)
  }

  /// P22-003/P22-004/P22-006/P22-007 interoperability: Apple's reader sees
  /// every markup subtype and renders the generated appearances.
  @Test func appleReadsMarkupVariantsAndRendersShapeFill() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let layout = try PageTextLayout.build(pageID: pageID, in: parsed.graph)
    let word = try #require(layout.words.first)
    let quads = AddHighlightCommand.quads(forClusterBounds: layout.clusters[word].map(\.bounds))
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextMarkupCommand(
          pageID: pageID, style: .underline, quads: quads, color: [1, 0, 0]),
        AddNoteCommand(pageID: pageID, at: [300, 400], contents: "Note", author: "Ada"),
        AddShapeCommand(
          pageID: pageID, kind: .square, rect: [100, 100, 200, 160], borderColor: [0, 0, 1],
          fillColor: [1, 1, 0], borderWidth: 2),
        AddLineCommand(
          pageID: pageID, from: [250, 300], to: [350, 300], color: [0, 0, 1], borderWidth: 2),
      ]), to: parsed.graph)
    let document = try #require(PDFDocument(data: try PDFWriter.write(graph)))
    let page = try #require(document.page(at: 0))
    #expect(Set(page.annotations.compactMap(\.type)) == ["Underline", "Text", "Square", "Line"])

    let context = try #require(
      CGContext(
        data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 612 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
    page.draw(with: .mediaBox, to: context)
    let image = try #require(context.makeImage())
    let raw = try #require(image.dataProvider?.data)
    let bytes = CFDataGetBytePtr(raw)!

    func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
      let offset = ((792 - 1 - y) * 612 + x) * 4
      return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }
    // The square interior renders as the yellow fill.
    let fill = pixel(150, 130)
    #expect(fill.0 > 240 && fill.1 > 240 && fill.2 < 60)
    // The underline strokes red pixels across the word.
    var red = 0
    for y in 705..<735 {
      for x in 40..<65 {
        let value = pixel(x, y)
        if value.0 > 200 && value.1 < 120 && value.2 < 120 { red += 1 }
      }
    }
    #expect(red > 10)
  }

  /// P22-005/P22-009/P22-010/P22-025 interoperability: Apple's reader sees
  /// free text, stamps, and links, resolves link targets, and renders the
  /// generated appearances.
  @Test func appleReadsFreeTextStampAndLink() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddFreeTextCommand(
          pageID: pageID, rect: [100, 600, 300, 650], text: "Hello", fillColor: [1, 1, 0.9],
          borderColor: [0.5, 0.5, 0.5], borderWidth: 1, contents: "Free"),
        AddStampCommand(
          pageID: pageID, rect: [200, 500, 360, 560], stampName: .approved, contents: "Stamp"),
        AddLinkCommand(
          pageID: pageID, rect: [100, 100, 260, 120],
          target: .uri("https://example.com/spdf"), contents: "External"),
        AddLinkCommand(
          pageID: pageID, rect: [300, 100, 420, 120], target: .page(0), contents: "Internal"),
      ]), to: parsed.graph)
    let document = try #require(PDFDocument(data: try PDFWriter.write(graph)))
    let page = try #require(document.page(at: 0))
    #expect(
      Set(page.annotations.compactMap(\.type)) == ["FreeText", "Stamp", "Link"])
    let links = page.annotations.filter { $0.type == "Link" }
    #expect(links.count == 2)
    #expect(links.contains { $0.url?.absoluteString == "https://example.com/spdf" })
    #expect(links.contains { $0.destination != nil })
    #expect(page.annotations.first { $0.type == "FreeText" }?.contents == "Free")
    #expect(page.annotations.first { $0.type == "Stamp" }?.contents == "Stamp")

    let context = try #require(
      CGContext(
        data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 612 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
    page.draw(with: .mediaBox, to: context)
    let image = try #require(context.makeImage())
    let raw = try #require(image.dataProvider?.data)
    let bytes = CFDataGetBytePtr(raw)!

    func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
      let offset = ((792 - 1 - y) * 612 + x) * 4
      return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }
    // The free-text fill renders inside its box.
    let fill = pixel(200, 625)
    #expect(fill.0 > 240 && fill.1 > 240 && fill.2 > 200)
    // The stamp border renders in its color.
    let stampBorder = pixel(201, 530)
    #expect(stampBorder.0 > 150 && stampBorder.1 < 80)
  }

  /// P22-008 interoperability: Apple's reader sees the ink annotation and
  /// renders the generated stroke.
  @Test func appleReadsAndRendersOwnedInk() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddInkCommand(
          pageID: pageID, strokes: [[100, 100, 200, 100]], color: [0, 0, 1], borderWidth: 3,
          contents: "ink")
      ]), to: parsed.graph)
    let document = try #require(PDFDocument(data: try PDFWriter.write(graph)))
    let page = try #require(document.page(at: 0))
    #expect(page.annotations.first { $0.type == "Ink" }?.contents == "ink")

    let context = try #require(
      CGContext(
        data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 612 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
    page.draw(with: .mediaBox, to: context)
    let image = try #require(context.makeImage())
    let raw = try #require(image.dataProvider?.data)
    let bytes = CFDataGetBytePtr(raw)!
    var blue = 0
    for y in 97..<104 {
      for x in 100..<201 {
        let offset = ((792 - 1 - y) * 612 + x) * 4
        if bytes[offset] < 80 && bytes[offset + 1] < 80 && bytes[offset + 2] > 150 { blue += 1 }
      }
    }
    #expect(blue > 100)
  }

  /// P22-024: non-GoTo actions are never performed automatically, including a
  /// JavaScript /OpenAction document and direct action calls.
  @Test @MainActor func viewerDoesNotExecuteNonGoToActions() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    var graph = parsed.graph
    guard case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[rootID]
    else {
      Issue.record("Fixture catalog is missing")
      return
    }
    catalog[PDFName("OpenAction")] = .dictionary([
      PDFName("S"): .name(PDFName("JavaScript")),
      PDFName("JS"): .string(Data("app.alert('hi')".utf8)),
    ])
    graph.objects[rootID] = .dictionary(catalog)
    #expect(ActionInventory.actions(in: graph, pageIDs: parsed.pageIDs).count == 1)

    let session = PDFViewingSession()
    try session.open(PDFSource(data: try PDFWriter.write(graph)))
    #expect(session.pageCount == 3)
    #expect(session.pageNumber == 1)
    // The view swallows non-GoTo actions and the delegate never opens links.
    session.view.perform(PDFActionURL(url: URL(string: "https://example.com")!))
    session.pdfViewWillClick(
      onLink: session.view, with: URL(string: "https://example.com")!)
    #expect(session.pageNumber == 1)
  }

  /// P22-028 interoperability: flattening removes the annotations from
  /// Apple's view while the page still renders the marks as content, and the
  /// untouched link keeps working.
  @Test func appleSeesFlattenedPageWithoutAnnotations() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let marked = try PDFEditingEngine.commit(
      PDFTransaction([
        AddHighlightCommand(
          pageID: pageID, quads: [42, 730, 62, 730, 42, 710, 62, 710], opacity: 1),
        AddLinkCommand(
          pageID: pageID, rect: [10, 10, 60, 30], target: .uri("https://example.com")),
      ]), to: parsed.graph)
    let flattened = try PDFEditingEngine.commit(
      PDFTransaction([FlattenAnnotationsCommand(pageID: pageID)]), to: marked)
    let document = try #require(PDFDocument(data: try PDFWriter.write(flattened)))
    let page = try #require(document.page(at: 0))
    #expect(page.annotations.count == 1)
    #expect(page.annotations.first?.type == "Link")
    #expect(page.annotations.first?.url?.absoluteString == "https://example.com")

    let context = try #require(
      CGContext(
        data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 612 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
    page.draw(with: .mediaBox, to: context)
    let image = try #require(context.makeImage())
    let raw = try #require(image.dataProvider?.data)
    let bytes = CFDataGetBytePtr(raw)!
    let offset = ((792 - 1 - 720) * 612 + 52) * 4
    #expect(bytes[offset] > 240 && bytes[offset + 1] > 200 && bytes[offset + 2] < 60)
  }

  /// P22-026: markup geometry stays correct on rotated and cropped pages,
  /// verified through PDFKit's page drawing.
  @Test func appleRendersMarkupOnRotatedAndCroppedPages() throws {
    // Rotated page: the fixture's third page is /Rotate 90.
    let rotated = try PDFParser.parse(PDFFixtures.threePages())
    let rotatedPageID = rotated.pageIDs[2]
    let marked = try PDFEditingEngine.commit(
      PDFTransaction([
        AddHighlightCommand(
          pageID: rotatedPageID, quads: [42, 730, 102, 730, 42, 710, 102, 710], opacity: 1)
      ]), to: rotated.graph)
    let rotatedDocument = try #require(PDFDocument(data: try PDFWriter.write(marked)))
    let rotatedPage = try #require(rotatedDocument.page(at: 2))
    #expect(rotatedPage.rotation == 90)
    let rotatedContext = try #require(
      CGContext(
        data: nil, width: 792, height: 612, bitsPerComponent: 8, bytesPerRow: 792 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    rotatedContext.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    rotatedContext.fill(CGRect(x: 0, y: 0, width: 792, height: 612))
    rotatedPage.draw(with: .mediaBox, to: rotatedContext)
    let rotatedImage = try #require(rotatedContext.makeImage())
    let rotatedRaw = try #require(rotatedImage.dataProvider?.data)
    let rotatedBytes = CFDataGetBytePtr(rotatedRaw)!
    // Rotate 90 maps page (x, y) to top-left display (y, 612 - x): the rect
    // [42,710,102,730] renders around (720, 540) in a 792×612 context.
    let rotatedOffset = ((612 - 1 - 540) * 792 + 720) * 4
    #expect(
      rotatedBytes[rotatedOffset] > 240 && rotatedBytes[rotatedOffset + 1] > 200
        && rotatedBytes[rotatedOffset + 2] < 60)

    // Cropped page: the annotation sits inside a CropBox smaller than the
    // MediaBox and still renders at the crop-relative position.
    let croppedParsed = try PDFParser.parse(PDFFixtures.onePage())
    let croppedPageID = croppedParsed.pageIDs[0]
    var croppedGraph = croppedParsed.graph
    guard case .dictionary(var croppedPage)? = croppedGraph.objects[croppedPageID] else {
      Issue.record("Fixture page is missing")
      return
    }
    croppedPage[PDFName("CropBox")] = .array([
      .integer(100), .integer(100), .integer(500), .integer(700),
    ])
    croppedGraph.objects[croppedPageID] = .dictionary(croppedPage)
    let croppedMarked = try PDFEditingEngine.commit(
      PDFTransaction([
        AddShapeCommand(
          pageID: croppedPageID, kind: .square, rect: [200, 200, 300, 260],
          borderColor: [0, 0, 0], fillColor: [1, 1, 0], borderWidth: 2)
      ]), to: croppedGraph)
    let croppedDocument = try #require(PDFDocument(data: try PDFWriter.write(croppedMarked)))
    let croppedPDFPage = try #require(croppedDocument.page(at: 0))
    let croppedContext = try #require(
      CGContext(
        data: nil, width: 400, height: 600, bitsPerComponent: 8, bytesPerRow: 400 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    croppedContext.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    croppedContext.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
    croppedPDFPage.draw(with: .cropBox, to: croppedContext)
    let croppedImage = try #require(croppedContext.makeImage())
    let croppedRaw = try #require(croppedImage.dataProvider?.data)
    let croppedBytes = CFDataGetBytePtr(croppedRaw)!
    // Crop origin (100, 100) maps to the context origin; the square interior
    // at page (250, 230) lands at (150, 130).
    let croppedOffset = ((600 - 1 - 130) * 400 + 150) * 4
    #expect(
      croppedBytes[croppedOffset] > 240 && croppedBytes[croppedOffset + 1] > 240
        && croppedBytes[croppedOffset + 2] < 60)
  }

  /// P24-025/P24-026 interoperability: Apple's reader sees filled field
  /// values on live widgets and renders the generated appearances.
  @Test func appleReadsFilledFormValuesAndAppearances() throws {
    let parsed = try PDFParser.parse(PDFFixtures.formPages())
    let filled = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormTextCommand(fieldName: "name", text: "Ada Lovelace"),
        SetFormButtonStateCommand(fieldName: "agree", state: PDFName("Yes")),
      ]), to: parsed.graph)
    let document = try #require(PDFDocument(data: try PDFWriter.write(filled)))
    let page = try #require(document.page(at: 0))
    let widgets = page.annotations.filter { $0.type == "Widget" }
    #expect(widgets.count >= 8)
    let textWidget = try #require(
      widgets.first { $0.widgetFieldType == PDFAnnotationWidgetSubtype.text })
    #expect(textWidget.widgetStringValue == "Ada Lovelace")
    let buttonWidget = try #require(
      widgets.first { $0.widgetFieldType == PDFAnnotationWidgetSubtype.button })
    #expect(buttonWidget.widgetStringValue == "Yes")

    let context = try #require(
      CGContext(
        data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 612 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
    page.draw(with: .mediaBox, to: context)
    let image = try #require(context.makeImage())
    let raw = try #require(image.dataProvider?.data)
    let bytes = CFDataGetBytePtr(raw)!
    func darkPixels(xRange: Range<Int>, yRange: Range<Int>) -> Int {
      var count = 0
      for y in yRange {
        for x in xRange {
          let offset = ((792 - 1 - y) * 612 + x) * 4
          if bytes[offset] < 120 && bytes[offset + 1] < 120 && bytes[offset + 2] < 120 {
            count += 1
          }
        }
      }
      return count
    }
    // The filled text and the checkbox mark render from generated appearances.
    #expect(darkPixels(xRange: 102..<298, yRange: 601..<619) > 20)
    #expect(darkPixels(xRange: 101..<119, yRange: 481..<499) > 5)
  }

  /// P24-024 interoperability: after flattening, Apple's reader sees no
  /// widgets while the page still renders the burned-in appearances.
  @Test func appleSeesFlattenedFormWithoutWidgets() throws {
    let parsed = try PDFParser.parse(PDFFixtures.formPages())
    let filled = try PDFEditingEngine.commit(
      PDFTransaction([SetFormTextCommand(fieldName: "name", text: "Ada")]), to: parsed.graph)
    let flattened = try PDFEditingEngine.commit(PDFTransaction([FlattenFormCommand()]), to: filled)
    let document = try #require(PDFDocument(data: try PDFWriter.write(flattened)))
    let page = try #require(document.page(at: 0))
    #expect(!page.annotations.contains { $0.type == "Widget" })

    let context = try #require(
      CGContext(
        data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 612 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
    page.draw(with: .mediaBox, to: context)
    let image = try #require(context.makeImage())
    let raw = try #require(image.dataProvider?.data)
    let bytes = CFDataGetBytePtr(raw)!
    var dark = 0
    for y in 601..<619 {
      for x in 102..<298 {
        let offset = ((792 - 1 - y) * 612 + x) * 4
        if bytes[offset] < 120 && bytes[offset + 1] < 120 && bytes[offset + 2] < 120 {
          dark += 1
        }
      }
    }
    #expect(dark > 10)
  }

  /// P26-012/P26-024/P26-025/P26-026 interoperability: the invisible layer
  /// extracts in Apple's reader on a rotated page while the raster still
  /// renders unchanged and no visible text appears.
  @Test func appleExtractsSearchableTextLayer() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    var graph = parsed.graph
    guard case .dictionary(var page)? = graph.objects[parsed.pageIDs[0]] else {
      Issue.record("Fixture page is missing")
      return
    }
    page[PDFName("Rotate")] = .integer(90)
    graph.objects[parsed.pageIDs[0]] = .dictionary(page)
    let lined = try PDFEditingEngine.commit(
      PDFTransaction([
        AddSearchableTextLayerCommand(
          pageID: parsed.pageIDs[0],
          lines: [
            SearchableTextLine(
              text: "Scanned invoice 42", rect: [100, 600, 300, 620], confidence: 0.9),
            SearchableTextLine(text: "Grüße", rect: [100, 560, 200, 580], confidence: 0.8),
          ])
      ]), to: graph)
    let document = try #require(PDFDocument(data: try PDFWriter.write(lined)))
    #expect(document.string?.contains("Scanned invoice 42") == true)
    #expect(document.string?.contains("Grüße") == true)

    let rotatedPage = try #require(document.page(at: 0))
    #expect(rotatedPage.rotation == 90)
    let context = try #require(
      CGContext(
        data: nil, width: 792, height: 612, bitsPerComponent: 8, bytesPerRow: 792 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 792, height: 612))
    rotatedPage.draw(with: .mediaBox, to: context)
    let image = try #require(context.makeImage())
    let raw = try #require(image.dataProvider?.data)
    let bytes = CFDataGetBytePtr(raw)!
    func pixel(_ xTop: Int, _ yTop: Int) -> (Int, Int, Int) {
      let offset = ((612 - 1 - yTop) * 792 + xTop) * 4
      return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }
    // Rotate 90 maps page (x, y) to top-left display (y, 612 − x): the green
    // image placement [80,600,200,720] lands at (600…720, 412…532).
    let green = pixel(660, 470)
    #expect(green.0 < 60 && green.1 > 200 && green.2 < 60)
    // Inside the layer box but outside the raster, the page stays white:
    // the text layer is invisible.
    let blank = pixel(610, 350)
    #expect(blank.0 > 240 && blank.1 > 240 && blank.2 > 240)
  }

  @Test func coreOutputHasRenderableCoreGraphicsPage() throws {
    let fixture = try PDFFixtures.onePage()
    let provider = try #require(CGDataProvider(data: fixture as CFData))
    let document = try #require(CGPDFDocument(provider))
    let page = try #require(document.page(at: 1))
    #expect(page.getBoxRect(.mediaBox).size == CGSize(width: 612, height: 792))
    let context = try #require(
      CGContext(
        data: nil, width: 306, height: 396, bitsPerComponent: 8, bytesPerRow: 306 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 306, height: 396))
    context.scaleBy(x: 0.5, y: 0.5)
    context.drawPDFPage(page)
    let image = try #require(context.makeImage())
    let data = try #require(image.dataProvider?.data)
    let bytes = CFDataGetBytePtr(data)!
    let length = CFDataGetLength(data)
    #expect((0..<length).contains { bytes[$0] < 240 })
  }

  @Test @MainActor func viewerSearchFindsNavigatesAndClears() throws {
    let session = PDFViewingSession()
    try session.open(PDFSource(data: PDFFixtures.threePages()))
    session.showSearch()
    #expect(session.isSearchVisible)
    session.searchText = "fixture - page"
    session.runSearch()
    #expect(session.searchMatchCount == 3)
    #expect(session.searchIndex == 1)
    #expect((session.view.currentSelection?.string ?? "").contains("fixture - page 1"))

    session.searchNext()
    #expect(session.searchIndex == 2)
    #expect((session.view.currentSelection?.string ?? "").contains("fixture - page 2"))
    session.searchPrevious()
    #expect(session.searchIndex == 1)
    session.searchPrevious()
    #expect(session.searchIndex == 3)  // wraps to the last match

    session.hideSearch()
    #expect(session.searchMatchCount == 0 && session.searchIndex == 0)
    #expect(!session.isSearchVisible)
  }

  @Test @MainActor func viewerNavigationAndZoomUseIndependentSessions() throws {
    let a = PDFViewingSession()
    let b = PDFViewingSession()
    #expect(a.view.autoScales)
    try a.open(PDFSource(data: PDFFixtures.threePages()))
    try b.open(PDFSource(data: PDFFixtures.onePage()))
    #expect(a.pageCount == 3 && b.pageCount == 1)
    a.lastPage()
    #expect(a.pageNumber == 3)
    #expect(b.pageNumber == 1)
    a.firstPage()
    #expect(a.pageNumber == 1)
    a.actualSize()
    #expect(a.scale == 1)
    a.go(to: 99)
    #expect(a.pageNumber == 1)
  }
}

extension RenderingTests {
  private func renderDarkPixels(document: PDFDocument) throws -> Int {
    let page = try #require(document.page(at: 0))
    let width = 153
    let height = 198
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    buffer.withUnsafeMutableBytes { pointer in
      guard let context = CGContext(
        data: pointer.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return }
      context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      context.saveGState()
      context.scaleBy(x: CGFloat(width) / 612, y: CGFloat(height) / 792)
      page.draw(with: .cropBox, to: context)
      context.restoreGState()
    }
    var dark = 0
    for pixel in 0..<(width * height) {
      if buffer[pixel * 4] < 200 && buffer[pixel * 4 + 1] < 200
        && buffer[pixel * 4 + 2] < 200
      {
        dark += 1
      }
    }
    return dark
  }

  /// P15-026/P15-027 (partial): composite output extracts and renders in
  /// the independent reader for both TrueType and CFF programs.
  @Test func compositeFontsReadInPDFKit() throws {
    func package(
      _ written: WrittenCompositeFont, text: String, fileKey: String
    ) throws -> Data {
      guard let codes = written.encode(text) else {
        throw PDFError(.malformed, "Encoding failed in test")
      }
      var content = Data("BT /F1 24 Tf 42 700 Td <".utf8)
      content.append(contentsOf: codes.map { String(format: "%02X", $0) }.joined().utf8)
      content.append(Data("> Tj ET\n".utf8))
      guard case .dictionary(let descendant) = written.descendant,
        case .dictionary(let descriptor) = written.descriptor
      else {
        throw PDFError(.malformed, "Composite structures malformed")
      }
      var descendantWithRefs = descendant
      descendantWithRefs[PDFName("FontDescriptor")] = .reference(PDFObjectID(6))
      descendantWithRefs[PDFName("ToUnicode")] = .reference(PDFObjectID(8))
      var descriptorWithFile = descriptor
      descriptorWithFile[PDFName(fileKey)] = .reference(PDFObjectID(7))
      let graph = PDFGraph(
        objects: [
          PDFObjectID(1): .dictionary([
            PDFName("Type"): .name(PDFName("Catalog")),
            PDFName("Pages"): .reference(PDFObjectID(2)),
          ]),
          PDFObjectID(2): .dictionary([
            PDFName("Type"): .name(PDFName("Pages")),
            PDFName("Count"): .integer(1),
            PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
          ]),
          PDFObjectID(3): .dictionary([
            PDFName("Type"): .name(PDFName("Page")),
            PDFName("Parent"): .reference(PDFObjectID(2)),
            PDFName("MediaBox"): .array([
              .integer(0), .integer(0), .integer(612), .integer(792),
            ]),
            PDFName("Resources"): .dictionary([
              PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(4))])
            ]),
            PDFName("Contents"): .reference(PDFObjectID(5)),
          ]),
          PDFObjectID(4): written.type0Dictionary(
            descendant: PDFObjectID(9), toUnicode: PDFObjectID(8),
            baseName: written.baseName),
          PDFObjectID(5): .stream(PDFStream(bytes: content)),
          PDFObjectID(6): .dictionary(descriptorWithFile),
          PDFObjectID(7): .stream(written.fontFile),
          PDFObjectID(8): .stream(written.toUnicode),
          PDFObjectID(9): .dictionary(descendantWithRefs),
        ],
        trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
      return try PDFWriter.write(graph)
    }
    guard
      let ttProgram = Data(base64Encoded: FontFixtureData.subsetProgramBase64),
      let cffProgram = Data(base64Encoded: FontFixtureData.cffProgramBase64)
    else {
      Issue.record("test font programs are corrupt")
      return
    }
    let tt = try CompositeFontWriter.write(
      program: ttProgram, baseName: "DejaVuSans", covering: "ABC")
    let ttData = try package(tt, text: "ABC", fileKey: "FontFile2")
    let ttDocument = try #require(PDFDocument(data: ttData))
    #expect(ttDocument.string?.contains("ABC") == true)
    #expect(try renderDarkPixels(document: ttDocument) > 20)
    let cff = try CompositeFontWriter.write(
      program: cffProgram, baseName: "DejaVuSans", covering: "ABC")
    let cffData = try package(cff, text: "ABC", fileKey: "FontFile3")
    let cffDocument = try #require(PDFDocument(data: cffData))
    #expect(cffDocument.string?.contains("ABC") == true)
    #expect(try renderDarkPixels(document: cffDocument) > 20)
  }

  /// P15-026/P15-027: text inserted through the editing command (not a
  /// hand-assembled graph) — multilingual within the supported narrow
  /// profile — extracts and renders in the independent reader.
  @Test func insertedMultilingualTextExtractsAndRendersInPDFKit() throws {
    guard let program = Data(base64Encoded: FontFixtureData.subsetProgramBase64) else {
      Issue.record("test font program is corrupt")
      return
    }
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let pageID = try #require(parsed.pageIDs.first)
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextObjectCommand(
          pageID: pageID, rect: [72, 500, 400, 560], text: "AâC ﬁ",
          style: AddedTextStyle(size: 18),
          customFont: CustomTextFont(program: program, familyName: "DejaVuSans"))
      ]), to: parsed.graph)
    let data = try PDFWriter.write(edited)
    let document = try #require(PDFDocument(data: data))
    let string = try #require(document.string)
    // The accented letter extracts exactly. The ligature arrives decomposed
    // ("fi") in both PDFKit and mutool on this toolchain (verified during
    // development: U+0066 U+0069); the owned layout keeps U+FB01 exact, so
    // only the decomposed form is required here and the precomposed form is
    // accepted for reader-version tolerance.
    #expect(string.contains("AâC"))
    #expect(string.contains("AâC fi") || string.contains("ﬁ"))
    #expect(try renderDarkPixels(document: document) > 20)
  }

  /// P14-026: the licensed multilingual fixture (Greek, Cyrillic, Hebrew in
  /// an embedded DejaVu subset) extracts the intended Unicode in the
  /// independent reader; the Hebrew line is stored in visual order and the
  /// reader's bidi returns reading order.
  @Test func multilingualFixtureExtractsInPDFKit() throws {
    let data = try PDFFixtures.multilingualPages()
    let document = try #require(PDFDocument(data: data))
    let string = try #require(document.string)
    #expect(string.contains("ΑΒΓ"))
    #expect(string.contains("БВ"))
    #expect(string.contains("אבש"))
  }

  /// P18-007: replacement through an embedded fallback program extracts in
  /// the independent reader (the ligature arrives decomposed, as usual).
  @Test func fallbackReplacementExtractsInPDFKit() throws {
    var graph = try PDFParser.parse(PDFFixtures.textWidthsPages()).graph
    let pageID = try #require(PDFPageTree.pageIDs(in: graph).first)
    guard let program = Data(base64Encoded: FontFixtureData.subsetProgramBase64) else {
      Issue.record("test font program is corrupt")
      return
    }
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextCommand(
          pageID: pageID, runIndex: 0, replacement: "Aﬁ",
          fallbackFont: CustomTextFont(program: program, familyName: "DejaVuSans"))
      ]), to: graph)
    let document = try #require(PDFDocument(data: PDFWriter.write(edited)))
    let string = try #require(document.string)
    #expect(string.contains("A"))
    #expect(string.contains("fi") || string.contains("ﬁ"))
    #expect(string.contains("CD"))
  }

  /// P15-027 (partial): an independent reader opens the writer's embedded
  /// font output and extracts the intended text.
  @Test func embeddedSubsetFontReadsInPDFKit() throws {
    guard
      let program = Data(base64Encoded: FontFixtureData.subsetProgramBase64)
    else {
      Issue.record("test font program is corrupt")
      return
    }
    let written = try FontWriter.writeTrueType(
      program: program, baseName: "DejaVuSans", covering: "ABC")
    guard let codes = written.encode("ABC") else {
      Issue.record("encoding failed")
      return
    }
    var content = Data("BT /F1 24 Tf 42 700 Td (".utf8)
    content.append(contentsOf: codes)
    content.append(Data(") Tj ET\n".utf8))
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(4))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(4): .dictionary({
          guard case .dictionary(let base) = written.fontDictionary else { return [:] }
          var font = base
          font[PDFName("FontDescriptor")] = .reference(PDFObjectID(6))
          font[PDFName("ToUnicode")] = .reference(PDFObjectID(8))
          return font
        }()),
        PDFObjectID(5): .stream(PDFStream(bytes: content)),
        PDFObjectID(6): .dictionary({
          guard case .dictionary(let baseDescriptor) = written.descriptor else { return [:] }
          var descriptor = baseDescriptor
          descriptor[PDFName("FontFile2")] = .reference(PDFObjectID(7))
          return descriptor
        }()),
        PDFObjectID(7): .stream(written.fontFile),
        PDFObjectID(8): .stream(written.toUnicode),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let data = try PDFWriter.write(graph)
    let document = try #require(PDFDocument(data: data))
    #expect(document.pageCount == 1)
    #expect(document.string?.contains("ABC") == true)
    // P15-027 (partial): the embedded glyphs render as ink, not .notdef
    // blanks, in the independent reader. PDFKit's thumbnail path skips
    // embedded-subset rasterization (blank), so the test draws through
    // PDFKit's real page rasterizer instead; our renderer and mutool agree
    // with it (verified visually during development).
    let page = try #require(document.page(at: 0))
    let width = 153
    let height = 198
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    buffer.withUnsafeMutableBytes { pointer in
      guard let context = CGContext(
        data: pointer.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return }
      context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      context.saveGState()
      context.scaleBy(x: CGFloat(width) / 612, y: CGFloat(height) / 792)
      page.draw(with: .cropBox, to: context)
      context.restoreGState()
    }
    // Antialiased edges read above 100 at this size (36 ink pixels here).
    var dark = 0
    for pixel in 0..<(width * height) {
      if buffer[pixel * 4] < 200 && buffer[pixel * 4 + 1] < 200
        && buffer[pixel * 4 + 2] < 200
      {
        dark += 1
      }
    }
    #expect(dark > 20)
  }
}
