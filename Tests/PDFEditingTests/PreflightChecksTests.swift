import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// P37-023–P37-029: preflight checks, explicit color conversion, print-resource
/// preservation, failing-fixture verification, transformation safety, and the
/// bounded/cancellable measurement.
@Suite("Preflight checks and color conversion")
struct PreflightChecksTests {
  private func fixture(
    embeddedFont: Bool = false, image: String? = nil, outputIntent: Bool = false,
    transparency: Bool = false, overprint: Bool = false, boxes: Bool = false,
    secondPageSize: [Double]? = nil, cmykImage: Bool = false, maskedImage: Bool = false,
    spotImage: Bool = false, iccImage: Bool = false
  ) -> PDFGraph {
    var objects: [PDFObjectID: PDFValue] = [:]
    var catalog: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Catalog")),
      PDFName("Pages"): .reference(PDFObjectID(2)),
    ]
    if outputIntent {
      catalog[PDFName("OutputIntents")] = .array([.reference(PDFObjectID(41))])
      objects[PDFObjectID(41)] = .dictionary([
        PDFName("Type"): .name(PDFName("OutputIntent")),
        PDFName("S"): .name(PDFName("GTS_PDFA1")),
        PDFName("DestOutputProfile"): .reference(PDFObjectID(42)),
      ])
      objects[PDFObjectID(42)] = .stream(PDFStream(bytes: Data([0, 0, 0, 0])))
    }
    objects[PDFObjectID(1)] = .dictionary(catalog)
    let kids: [PDFValue] =
      secondPageSize == nil
      ? [.reference(PDFObjectID(4))] : [.reference(PDFObjectID(4)), .reference(PDFObjectID(6))]
    objects[PDFObjectID(2)] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(Int64(kids.count)),
      PDFName("Kids"): .array(kids),
    ])
    var font: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Helvetica")),
      PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
    ]
    if embeddedFont {
      font[PDFName("FontDescriptor")] = .reference(PDFObjectID(30))
      objects[PDFObjectID(30)] = .dictionary([
        PDFName("Type"): .name(PDFName("FontDescriptor")),
        PDFName("FontName"): .name(PDFName("Helvetica")),
        PDFName("Flags"): .integer(32),
        PDFName("FontFile2"): .reference(PDFObjectID(31)),
      ])
      objects[PDFObjectID(31)] = .stream(PDFStream(bytes: Data([0, 1, 2, 3])))
    }
    objects[PDFObjectID(3)] = .dictionary(font)

    var resources: [PDFName: PDFValue] = [
      PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
    ]
    var xobjects: [PDFName: PDFValue] = [:]
    func imageStream(
      width: Int, height: Int, colorSpace: PDFValue, samples: Data, extra: [PDFName: PDFValue] = [:]
    ) -> PDFStream {
      var dictionary: [PDFName: PDFValue] = [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Image")),
        PDFName("Width"): .integer(Int64(width)),
        PDFName("Height"): .integer(Int64(height)),
        PDFName("ColorSpace"): colorSpace,
        PDFName("BitsPerComponent"): .integer(8),
      ]
      for (key, value) in extra { dictionary[key] = value }
      return PDFStream(dictionary: dictionary, bytes: samples)
    }
    var nextID = 20
    var drawnImages: [String] = []
    func addImage(_ name: String, stream: PDFStream) {
      let id = PDFObjectID(nextID)
      nextID += 1
      objects[id] = .stream(stream)
      xobjects[PDFName(name)] = .reference(id)
      drawnImages.append(name)
    }
    if let image {
      let samples = Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])
      let space: PDFValue =
        image == "rgb" ? .name(PDFName("DeviceRGB")) : .name(PDFName("DeviceGray"))
      let bytes = image == "rgb" ? samples : Data([10, 20, 30, 40])
      addImage("Im1", stream: imageStream(width: 2, height: 2, colorSpace: space, samples: bytes))
    }
    if cmykImage {
      addImage(
        "ImC",
        stream: imageStream(
          width: 2, height: 2, colorSpace: .name(PDFName("DeviceCMYK")),
          samples: Data(repeating: 0, count: 16)))
    }
    if maskedImage {
      addImage(
        "ImM",
        stream: imageStream(
          width: 2, height: 2, colorSpace: .name(PDFName("DeviceRGB")),
          samples: Data(repeating: 0, count: 12),
          extra: [PDFName("SMask"): .reference(PDFObjectID(90))]))
      objects[PDFObjectID(90)] = .stream(
        PDFStream(
          dictionary: [
            PDFName("Type"): .name(PDFName("XObject")),
            PDFName("Subtype"): .name(PDFName("Image")),
            PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
            PDFName("ColorSpace"): .name(PDFName("DeviceGray")),
            PDFName("BitsPerComponent"): .integer(8),
          ], bytes: Data([255, 255, 255, 255])))
    }
    if spotImage {
      addImage(
        "ImS",
        stream: imageStream(
          width: 2, height: 2,
          colorSpace: .array([
            .name(PDFName("Separation")), .name(PDFName("Pantone")),
            .name(PDFName("DeviceCMYK")), .reference(PDFObjectID(91)),
          ]), samples: Data(repeating: 0, count: 4)))
      objects[PDFObjectID(91)] = .stream(PDFStream(bytes: Data([0, 0, 0, 0])))
    }
    if iccImage {
      addImage(
        "ImI",
        stream: imageStream(
          width: 2, height: 2,
          colorSpace: .array([.name(PDFName("ICCBased")), .reference(PDFObjectID(92))]),
          samples: Data(repeating: 0, count: 12)))
      objects[PDFObjectID(92)] = .stream(
        PDFStream(
          dictionary: [
            PDFName("N"): .integer(3), PDFName("Alternate"): .name(PDFName("DeviceRGB")),
          ], bytes: Data([0, 0, 0, 0])))
    }
    if !xobjects.isEmpty { resources[PDFName("XObject")] = .dictionary(xobjects) }
    var graphicsStates: [PDFName: PDFValue] = [:]
    if transparency {
      graphicsStates[PDFName("GS1")] = .dictionary([PDFName("CA"): .real(0.5)])
    }
    if overprint {
      graphicsStates[PDFName("GS2")] = .dictionary([PDFName("OP"): .boolean(true)])
    }
    if !graphicsStates.isEmpty { resources[PDFName("ExtGState")] = .dictionary(graphicsStates) }
    var page: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Page")),
      PDFName("Parent"): .reference(PDFObjectID(2)),
      PDFName("MediaBox"): .array([
        .integer(0), .integer(0), .integer(612), .integer(792),
      ]),
      PDFName("Resources"): .dictionary(resources),
      PDFName("Contents"): .reference(PDFObjectID(5)),
    ]
    if boxes {
      page[PDFName("TrimBox")] = .array([
        .integer(10), .integer(10), .integer(602), .integer(782),
      ])
      page[PDFName("BleedBox")] = .array([
        .integer(5), .integer(5), .integer(607), .integer(787),
      ])
    }
    objects[PDFObjectID(4)] = .dictionary(page)
    var content = "BT /F1 12 Tf 72 700 Td (Hello) Tj ET\n"
    for (offset, name) in drawnImages.enumerated() {
      let y = 500 - Double(offset) * 60
      content += "q 60 0 0 60 72 \(y) cm /\(name) Do Q\n"
    }
    objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data(content.utf8)))
    if let secondPageSize {
      objects[PDFObjectID(6)] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array(secondPageSize.map { PDFValue.real($0) }),
        PDFName("Resources"): .dictionary([
          PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
        ]),
        PDFName("Contents"): .reference(PDFObjectID(7)),
      ])
      objects[PDFObjectID(7)] = .stream(
        PDFStream(bytes: Data("BT /F1 12 Tf 72 700 Td (Second) Tj ET\n".utf8)))
    }
    return PDFGraph(
      version: "1.7", objects: objects,
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  // MARK: - P37-023/P37-025/P37-027

  @Test func checksReportFindingsAndNoPDFXClaim() throws {
    let graph = fixture(image: "rgb", transparency: true, overprint: true)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let report = try PreflightCheckReport.run(graph, pageIDs: pageIDs)
    let rules = report.findings.map(\.rule)
    #expect(rules.contains("Font embedding"))
    #expect(rules.contains("Image resolution"))
    #expect(rules.contains("Color management"))
    #expect(rules.contains("Transparency"))
    #expect(rules.contains("Overprint"))
    #expect(rules.contains("Print boxes"))
    #expect(rules.contains("PDF/X"))
    #expect(report.errorCount == 1)  // font embedding
    #expect(report.warningCount >= 2)
    #expect(!PreflightCheckReport.pdfxSupported)
    let text = report.report()
    #expect(text.contains("Read-only"))
    #expect(text.contains("No ISO PDF/X conformance is claimed"))
    // Nothing was modified: the graph is untouched by running checks.
    let again = try PreflightCheckReport.run(graph, pageIDs: pageIDs)
    #expect(again.findings.count == report.findings.count)
  }

  @Test func failingFixturesTriggerTheExpectedRules() throws {
    // Mixed page sizes and spot colors.
    let graph = fixture(
      boxes: true, secondPageSize: [0, 0, 842, 595], spotImage: true, iccImage: true)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let report = try PreflightCheckReport.run(graph, pageIDs: pageIDs)
    #expect(report.findings.contains { $0.rule == "Page geometry" && $0.severity == .warning })
    #expect(report.findings.contains { $0.rule == "Spot colors" && $0.severity == .warning })
    #expect(report.findings.contains { $0.rule == "ICC profiles" && $0.severity == .info })
    // Boxes are present on the first page; the second page lacks them.
    #expect(
      report.findings.contains { $0.rule == "Print boxes" && $0.detail.contains("1 page") })
  }

  // MARK: - P37-024

  @Test func colorConversionConvertsSupportedImagesAndRefusesOthers() throws {
    let graph = fixture(image: "rgb", cmykImage: true, maskedImage: true)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let converted = try ColorConversion.convert(graph, pageIDs: pageIDs, to: .gray)
    #expect(converted.report.convertedImages == 1)
    #expect(converted.report.fromSpaces == ["DeviceRGB"])
    #expect(converted.report.refused.contains { $0.contains("DeviceCMYK") })
    #expect(converted.report.refused.contains { $0.contains("masked") })
    // The converted image is DeviceGray with luminance samples.
    let images = try PDFImageInventory.images(in: converted.graph, pageIDs: pageIDs)
    let image = try #require(images.first { $0.colorSpace == "DeviceGray" && $0.width == 2 })
    let objectID = try #require(image.objectID)
    guard case .stream(let stream)? = converted.graph.objects[objectID] else {
      Issue.record("converted stream missing")
      return
    }
    let samples = try PDFFilters.decoded(stream)
    #expect(samples == Data([76, 150, 29, 255]))
    // The original graph is untouched (conversion returns a new graph).
    let originalImages = try PDFImageInventory.images(in: graph, pageIDs: pageIDs)
    #expect(originalImages.contains { $0.colorSpace == "DeviceRGB" })

    // Gray → RGB replicates the samples.
    let grayGraph = fixture(image: "gray")
    let toRGB = try ColorConversion.convert(grayGraph, pageIDs: pageIDs, to: .rgb)
    #expect(toRGB.report.convertedImages == 1)
    let rgbImage = try #require(
      try PDFImageInventory.images(in: toRGB.graph, pageIDs: pageIDs)
        .first { $0.colorSpace == "DeviceRGB" })
    let rgbObjectID = try #require(rgbImage.objectID)
    guard case .stream(let rgbStream)? = toRGB.graph.objects[rgbObjectID] else {
      Issue.record("rgb stream missing")
      return
    }
    let rgbSamples = try PDFFilters.decoded(rgbStream)
    #expect(rgbSamples == Data([10, 10, 10, 20, 20, 20, 30, 30, 30, 40, 40, 40]))
  }

  // MARK: - P37-026

  @Test func printResourcesSurviveUnrelatedEdits() throws {
    let graph = fixture(
      image: "rgb", outputIntent: true, overprint: true, spotImage: true, iccImage: true)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let imagesBefore = try PDFImageInventory.images(in: graph, pageIDs: pageIDs)
    let outputIntentBefore = graph.objects[PDFObjectID(41)]
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([RotatePagesCommand(pageIDs: [pageIDs[0]], byDegrees: 90)]), to: graph)
    // The unrelated edit changed only the page's /Rotate.
    #expect(edited.objects[PDFObjectID(41)] == outputIntentBefore)
    for image in imagesBefore {
      guard let objectID = image.objectID else { continue }
      #expect(edited.objects[objectID] == graph.objects[objectID], "image \(image.name) changed")
    }
    // The print inventory still sees the same resources.
    let after = PrintPreflightInventory.inventory(edited, pageIDs: pageIDs)
    #expect(after.spotColorSpaces == 1)
    #expect(after.iccProfiles == 1)
    #expect(after.overprintUses == 1)
    #expect(after.hasOutputIntent)
  }

  // MARK: - P37-028

  @Test func correctiveTransformationsDoNotDiscardContent() throws {
    // A document with actions and embedded files: staging safe transformations
    // must not touch pages, content, or the embedded file payload.
    var objects: [PDFObjectID: PDFValue] = [:]
    var catalog: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Catalog")),
      PDFName("Pages"): .reference(PDFObjectID(2)),
      PDFName("OpenAction"): .dictionary([
        PDFName("S"): .name(PDFName("JavaScript")),
        PDFName("JS"): .string(Data("app.alert(1)".utf8)),
      ]),
      PDFName("Names"): .dictionary([
        PDFName("EmbeddedFiles"): .dictionary([
          PDFName("Names"): .array([.string(Data("file".utf8)), .reference(PDFObjectID(50))])
        ])
      ]),
    ]
    objects[PDFObjectID(1)] = .dictionary(catalog)
    objects[PDFObjectID(2)] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(1),
      PDFName("Kids"): .array([.reference(PDFObjectID(4))]),
    ])
    objects[PDFObjectID(4)] = .dictionary([
      PDFName("Type"): .name(PDFName("Page")),
      PDFName("Parent"): .reference(PDFObjectID(2)),
      PDFName("MediaBox"): .array([
        .integer(0), .integer(0), .integer(612), .integer(792),
      ]),
      PDFName("Contents"): .reference(PDFObjectID(5)),
    ])
    objects[PDFObjectID(5)] = .stream(
      PDFStream(bytes: Data("BT /F1 12 Tf 72 700 Td (Keep me) Tj ET\n".utf8)))
    objects[PDFObjectID(50)] = .dictionary([
      PDFName("Type"): .name(PDFName("Filespec")),
      PDFName("F"): .string(Data("file.txt".utf8)),
      PDFName("EF"): .dictionary([PDFName("F"): .reference(PDFObjectID(51))]),
    ])
    objects[PDFObjectID(51)] = .stream(PDFStream(bytes: Data("payload".utf8)))
    let graph = PDFGraph(
      version: "1.7", objects: objects,
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let plan = ArchivalDerivative.plan(graph, pageIDs: pageIDs)
    // The embedded-file removal is never in the safe set.
    #expect(!plan.safeKinds.contains(.removeEmbeddedFiles))
    let staged = try ArchivalDerivative.stage(graph, plan: plan, applying: plan.safeKinds)
    // Pages, content, and the embedded payload are byte-identical.
    #expect(staged.graph.objects[PDFObjectID(4)] == graph.objects[PDFObjectID(4)])
    #expect(staged.graph.objects[PDFObjectID(5)] == graph.objects[PDFObjectID(5)])
    #expect(staged.graph.objects[PDFObjectID(51)] == graph.objects[PDFObjectID(51)])
    #expect(staged.graph.objects[PDFObjectID(50)] == graph.objects[PDFObjectID(50)])
    // Only the executable action was removed.
    guard case .dictionary(let stagedCatalog)? = staged.graph.objects[PDFObjectID(1)] else {
      Issue.record("catalog missing")
      return
    }
    #expect(stagedCatalog[PDFName("OpenAction")] == nil)
    #expect(stagedCatalog[PDFName("Names")] != nil)
    // The report names what was applied and skipped.
    #expect(staged.applied.contains(.removeExecutableActions))
    #expect(staged.skipped.contains(.removeEmbeddedFiles))
  }

  // MARK: - P37-029

  @Test func validationMeasurementIsBoundedAndCancellable() async throws {
    // A 60-page synthetic document.
    var objects: [PDFObjectID: PDFValue] = [:]
    var kids: [PDFValue] = []
    var nextID = 100
    for page in 1...60 {
      let contentID = PDFObjectID(nextID)
      let pageID = PDFObjectID(nextID + 1)
      nextID += 2
      var content = "BT /F1 12 Tf 72 700 Td (Page \(page) line) Tj ET\n"
      content += "q 120 0 0 120 72 500 cm /Im1 Do Q\n"
      objects[contentID] = .stream(PDFStream(bytes: Data(content.utf8)))
      objects[pageID] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(612), .integer(792),
        ]),
        PDFName("Resources"): .dictionary([
          PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))]),
          PDFName("XObject"): .dictionary([PDFName("Im1"): .reference(PDFObjectID(80))]),
        ]),
        PDFName("Contents"): .reference(contentID),
      ])
      kids.append(.reference(pageID))
    }
    objects[PDFObjectID(1)] = .dictionary([
      PDFName("Type"): .name(PDFName("Catalog")),
      PDFName("Pages"): .reference(PDFObjectID(2)),
    ])
    objects[PDFObjectID(2)] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(60),
      PDFName("Kids"): .array(kids),
    ])
    objects[PDFObjectID(3)] = .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Helvetica")),
      PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
    ])
    objects[PDFObjectID(80)] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Image")),
          PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
          PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
          PDFName("BitsPerComponent"): .integer(8),
        ], bytes: Data(repeating: 128, count: 12)))
    let graph = PDFGraph(
      version: "1.7", objects: objects,
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let pageIDs = try PDFPageTree.pageIDs(in: graph)

    func millis(_ duration: Duration) -> Int {
      Int(
        duration.components.seconds * 1000
          + duration.components.attoseconds / 1_000_000_000_000_000)
    }
    let start = ContinuousClock.now
    let archival = ArchivalInventory.inventory(graph, pageIDs: pageIDs)
    let preflight = PrintPreflightInventory.inventory(graph, pageIDs: pageIDs)
    let checks = try PreflightCheckReport.run(graph, pageIDs: pageIDs)
    let plan = ArchivalDerivative.plan(graph, pageIDs: pageIDs)
    let duration = ContinuousClock.now - start
    print(
      "[P37-029] 60 pages: inventory+checks+plan \(millis(duration)) ms; "
        + "\(archival.findings.count) archival findings, \(preflight.images.count) images, "
        + "\(checks.findings.count) checks, \(plan.transformations.count) transformations")
    #expect(millis(duration) < 10_000)
    #expect(preflight.images.count == 60)
    #expect(checks.findings.contains { $0.rule == "Image resolution" })

    // Cancellation: a cancelled conversion stops promptly. The task is given
    // a chance to start first; the bound covers scheduling delays under load.
    let task = Task {
      try ColorConversion.convert(graph, pageIDs: pageIDs, to: .gray)
    }
    await Task.yield()
    let cancelStart = ContinuousClock.now
    task.cancel()
    let result = await task.result
    let latency = millis(ContinuousClock.now - cancelStart)
    print("[P37-029] cancellation latency \(latency) ms")
    #expect(latency < 5_000)
    switch result {
    case .success:
      // The conversion may have finished before the cancellation arrived.
      break
    case .failure(let error):
      #expect(error is CancellationError)
    }
  }
}
