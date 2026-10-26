import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// IMG-03 evidence: color/mask/codec semantics, honest extraction
/// classification, explicit RGB conversion, and byte preservation across
/// geometry edits.
@Suite("Image color, mask and codec semantics")
struct ImageSemanticsTests {
  // MARK: - Fixtures

  private func makeGraph(
    pageContents: [String], images: [(name: String, stream: PDFStream)]
  ) throws -> PDFGraph {
    let pageIDs = (0..<pageContents.count).map { PDFObjectID(3 + $0) }
    let contentStart = 3 + pageContents.count
    let imageStart = contentStart + pageContents.count
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(Int64(pageContents.count)),
        PDFName("Kids"): .array(pageIDs.map { .reference($0) }),
      ]),
    ]
    var xobjects: [PDFName: PDFValue] = [:]
    for (index, image) in images.enumerated() {
      let id = PDFObjectID(imageStart + index)
      objects[id] = .stream(image.stream)
      xobjects[PDFName(image.name)] = .reference(id)
    }
    let resources = PDFValue.dictionary([PDFName("XObject"): .dictionary(xobjects)])
    for (index, pageID) in pageIDs.enumerated() {
      objects[pageID] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(612), .integer(792),
        ]),
        PDFName("Resources"): resources,
        PDFName("Contents"): .reference(PDFObjectID(contentStart + index)),
      ])
      objects[PDFObjectID(contentStart + index)] = .stream(
        PDFStream(bytes: Data(pageContents[index].utf8)))
    }
    let graph = PDFGraph(
      objects: objects, trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    return try PDFParser.parse(PDFWriter.write(graph)).graph
  }

  private func rgbImage(_ bytes: Data = Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255]))
    -> PDFStream
  {
    PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Image")),
        PDFName("Width"): .integer(2),
        PDFName("Height"): .integer(2),
        PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
        PDFName("BitsPerComponent"): .integer(8),
      ], bytes: bytes)
  }

  private func cmykImage() -> PDFStream {
    PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Image")),
        PDFName("Width"): .integer(2),
        PDFName("Height"): .integer(2),
        PDFName("ColorSpace"): .name(PDFName("DeviceCMYK")),
        PDFName("BitsPerComponent"): .integer(8),
      ], bytes: Data(repeating: 32, count: 16))
  }

  private func dctImage(colorSpace: PDFValue = .name(PDFName("DeviceCMYK")))
    -> PDFStream
  {
    PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Image")),
        PDFName("Width"): .integer(8),
        PDFName("Height"): .integer(8),
        PDFName("ColorSpace"): colorSpace,
        PDFName("BitsPerComponent"): .integer(8),
        PDFName("Filter"): .name(PDFName("DCTDecode")),
      ], bytes: Data([0xFF, 0xD8, 1, 2, 0xFF, 0xD9]))
  }

  private func jpxImage(colorSpace: PDFValue = .name(PDFName("DeviceCMYK")))
    -> PDFStream
  {
    PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Image")),
        PDFName("Width"): .integer(8),
        PDFName("Height"): .integer(8),
        PDFName("ColorSpace"): colorSpace,
        PDFName("BitsPerComponent"): .integer(8),
        PDFName("Filter"): .name(PDFName("JPXDecode")),
      ], bytes: Data([0, 0, 0, 12, 106, 80, 32, 32]))
  }

  private func grayMaskImage() -> PDFStream {
    PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Image")),
        PDFName("Width"): .integer(2),
        PDFName("Height"): .integer(2),
        PDFName("ColorSpace"): .name(PDFName("DeviceGray")),
        PDFName("BitsPerComponent"): .integer(8),
      ], bytes: Data([0, 64, 128, 255]))
  }

  private func stencilImage() -> PDFStream {
    PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Image")),
        PDFName("Width"): .integer(2),
        PDFName("Height"): .integer(2),
        PDFName("ImageMask"): .boolean(true),
        PDFName("BitsPerComponent"): .integer(1),
      ], bytes: Data([0xF0, 0xF0]))
  }

  /// Shared resources: one image object referenced from both pages.
  private func sharedImageGraph(pageContent: String, image: PDFStream) throws
    -> (graph: PDFGraph, imageID: PDFObjectID)
  {
    let graph = try makeGraph(
      pageContents: [pageContent, pageContent], images: [("Im1", image)])
    let imageID = PDFObjectID(7)
    #expect(graph.objects[imageID] != nil)
    return (graph, imageID)
  }

  private func imagesPageContent(size: Double = 50) -> String {
    "q \(size) 0 0 \(size) 100 300 cm /Im1 Do Q\n"
  }

  // MARK: - Semantics description

  @Test func describesColorSpacesMasksAndDecodeArrays() throws {
    let iccProfile = PDFStream(
      dictionary: [PDFName("N"): .integer(4)],
      bytes: Data(repeating: 1, count: 16))
    let graph = try makeGraph(
      pageContents: [imagesPageContent()],
      images: [("Im1", cmykImage())])

    let reparse = try PDFParser.parse(PDFWriter.write(graph))
    let cmyk = try ImageSemanticsInspector.describe(
      imageID: PDFObjectID(5), in: reparse.graph)
    #expect(cmyk.family == .deviceCMYK)
    #expect(cmyk.bitsPerComponent == 8)
    #expect(cmyk.mask == .none)
    #expect(cmyk.decode == nil)
    #expect(cmyk.decodeIsIdentity)
    #expect(cmyk.replacementPolicy != .directRGB8(transparencyRequired: false))
    if case .explicitConversion = cmyk.replacementPolicy {
    } else {
      Issue.record("CMYK replacement must require an explicit conversion")
    }

    // ICCBased family resolves N and alternate from the profile dictionary.
    var iccGraph = try makeGraph(
      pageContents: [imagesPageContent()], images: [("Im1", rgbImage())])
    var iccDict = streamDictionary(iccGraph, PDFObjectID(5))
    iccDict[PDFName("ColorSpace")] = .array([
      .name(PDFName("ICCBased")), .reference(PDFObjectID(6)),
      .name(PDFName("DeviceCMYK")), .integer(4),
    ])
    iccGraph.objects[PDFObjectID(5)] = .stream(
      PDFStream(dictionary: iccDict, bytes: streamBytes(iccGraph, PDFObjectID(5))))
    iccGraph.objects[PDFObjectID(6)] = .stream(iccProfile)
    let iccParsed = try PDFParser.parse(PDFWriter.write(iccGraph))
    let icc = try ImageSemanticsInspector.describe(
      imageID: PDFObjectID(5), in: iccParsed.graph)
    #expect(icc.family == .iccBased(components: 4, alternate: "DeviceCMYK"))
    #expect(icc.family.components == 4)

    // Soft mask, color-key mask, stencil and non-identity decode.
    var masked = try makeGraph(
      pageContents: [imagesPageContent()],
      images: [("Im1", rgbImage()), ("M1", grayMaskImage())])
    var maskedDict = streamDictionary(masked, PDFObjectID(5))
    maskedDict[PDFName("SMask")] = .reference(PDFObjectID(6))
    masked.objects[PDFObjectID(5)] = .stream(
      PDFStream(dictionary: maskedDict, bytes: streamBytes(masked, PDFObjectID(5))))
    let maskedParsed = try PDFParser.parse(PDFWriter.write(masked))
    let soft = try ImageSemanticsInspector.describe(
      imageID: PDFObjectID(5), in: maskedParsed.graph)
    #expect(soft.mask == .softMask(PDFObjectID(6)))
    #expect(soft.replacementPolicy == .directRGB8(transparencyRequired: true))

    var colorKey = try makeGraph(
      pageContents: [imagesPageContent()], images: [("Im1", rgbImage())])
    var colorKeyDict = streamDictionary(colorKey, PDFObjectID(5))
    colorKeyDict[PDFName("Mask")] = .array([
      .integer(0), .integer(255), .integer(0),
    ])
    colorKey.objects[PDFObjectID(5)] = .stream(
      PDFStream(dictionary: colorKeyDict, bytes: streamBytes(colorKey, PDFObjectID(5))))
    let colorKeyParsed = try PDFParser.parse(PDFWriter.write(colorKey))
    let keyed = try ImageSemanticsInspector.describe(
      imageID: PDFObjectID(5), in: colorKeyParsed.graph)
    #expect(keyed.mask == .colorKey([0, 255, 0]))
    if case .explicitConversion = keyed.replacementPolicy {
    } else {
      Issue.record("Color-key transparency must require an explicit conversion")
    }

    var stencil = try makeGraph(
      pageContents: [imagesPageContent()], images: [("Im1", stencilImage())])
    _ = stencil
    let stencilParsed = try PDFParser.parse(PDFWriter.write(stencil))
    let stencilSemantics = try ImageSemanticsInspector.describe(
      imageID: PDFObjectID(5), in: stencilParsed.graph)
    #expect(stencilSemantics.mask == .stencil)
    if case .unsupported = stencilSemantics.replacementPolicy {
    } else {
      Issue.record("Stencil images cannot use the RGB replacement path")
    }

    let decoded = try makeGraph(
      pageContents: [imagesPageContent()],
      images: [("Im1", rgbImage())])
    var decodedDict = streamDictionary(decoded, PDFObjectID(5))
    decodedDict[PDFName("Decode")] = .array([
      .integer(1), .integer(0), .integer(1), .integer(0), .integer(1), .integer(0),
    ])
    var decodedGraph = decoded
    decodedGraph.objects[PDFObjectID(5)] = .stream(
      PDFStream(dictionary: decodedDict, bytes: streamBytes(decoded, PDFObjectID(5))))
    let decodedParsed = try PDFParser.parse(PDFWriter.write(decodedGraph))
    let inverted = try ImageSemanticsInspector.describe(
      imageID: PDFObjectID(5), in: decodedParsed.graph)
    #expect(!inverted.decodeIsIdentity)
    #expect(inverted.decodeArrayPresent)
    if case .explicitConversion = inverted.replacementPolicy {
    } else {
      Issue.record("A non-identity decode array must not use the direct RGB path")
    }
  }

  private func streamDictionary(
    _ graph: PDFGraph, _ id: PDFObjectID
  ) -> [PDFName: PDFValue] {
    guard case .stream(let stream)? = graph.objects[id] else { return [:] }
    return stream.dictionary
  }

  private func streamBytes(_ graph: PDFGraph, _ id: PDFObjectID) -> Data {
    guard case .stream(let stream)? = graph.objects[id] else { return Data() }
    return stream.bytes
  }

  // MARK: - Extraction classification

  @Test func extractionPreservesStandaloneCodecsAndFlagsConversions() throws {
    let graph = try makeGraph(
      pageContents: [
        "q 50 0 0 50 100 300 cm /ImCMYK Do Q\nq 50 0 0 50 200 300 cm /ImJPX Do Q\nq 50 0 0 50 300 300 cm /ImDecode Do Q\nq 50 0 0 50 400 300 cm /ImSoft Do Q\nq 50 0 0 50 100 100 cm /ImKey Do Q\nq 50 0 0 50 200 100 cm /ImStencil Do Q\n"
      ],
      images: [
        ("ImCMYK", dctImage()),
        ("ImJPX", jpxImage()),
        ("ImDecode", rgbImage()),
        ("ImSoft", rgbImage()),
        ("ImKey", rgbImage()),
        ("ImStencil", stencilImage()),
      ])
    var editedGraph = graph
    editedGraph.objects[PDFObjectID(11)] = .stream(grayMaskImage())
    var decodeDict = streamDictionary(editedGraph, PDFObjectID(7))
    decodeDict[PDFName("Decode")] = .array([
      .integer(1), .integer(0), .integer(1), .integer(0), .integer(1), .integer(0),
    ])
    editedGraph.objects[PDFObjectID(7)] = .stream(
      PDFStream(dictionary: decodeDict, bytes: streamBytes(editedGraph, PDFObjectID(7))))
    var softDict = streamDictionary(editedGraph, PDFObjectID(8))
    softDict[PDFName("SMask")] = .reference(PDFObjectID(11))
    editedGraph.objects[PDFObjectID(8)] = .stream(
      PDFStream(dictionary: softDict, bytes: streamBytes(editedGraph, PDFObjectID(8))))
    var keyDict = streamDictionary(editedGraph, PDFObjectID(9))
    keyDict[PDFName("Mask")] = .array([.integer(0), .integer(255), .integer(0)])
    editedGraph.objects[PDFObjectID(9)] = .stream(
      PDFStream(dictionary: keyDict, bytes: streamBytes(editedGraph, PDFObjectID(9))))
    let parsed = try PDFParser.parse(PDFWriter.write(editedGraph))

    let cmyk = try ImageOriginalExtraction.extract(imageID: PDFObjectID(5), in: parsed.graph)
    #expect(cmyk.preservation == .originalEncodedBytes(
      extension: "jpg",
      note: "Original JPEG bytes preserved byte-for-byte with DeviceCMYK color"))
    #expect(cmyk.usableAsStandaloneFile)
    #expect(cmyk.suggestedExtension == "jpg")
    #expect(cmyk.colorFamily == .deviceCMYK)

    let jpx = try ImageOriginalExtraction.extract(imageID: PDFObjectID(6), in: parsed.graph)
    if case .originalEncodedBytes(let ext, let note) = jpx.preservation {
      #expect(ext == "jp2")
      #expect(note.contains("JPEG 2000"))
    } else {
      Issue.record("JPX original bytes must be preserved")
    }

    let decode = try ImageOriginalExtraction.extract(imageID: PDFObjectID(7), in: parsed.graph)
    if case .explicitColorConversion(let reason) = decode.preservation {
      #expect(reason.contains("Decode"))
    } else {
      Issue.record("A non-identity decode array must require explicit conversion")
    }

    let soft = try ImageOriginalExtraction.extract(imageID: PDFObjectID(8), in: parsed.graph)
    if case .alphaPreservingExport(let note) = soft.preservation {
      #expect(note.contains("soft mask"))
      #expect(!soft.usableAsStandaloneFile)
    } else {
      Issue.record("Raw 8-bit RGB with a soft mask must support alpha-preserving export")
    }

    let key = try ImageOriginalExtraction.extract(imageID: PDFObjectID(9), in: parsed.graph)
    if case .renderedReconstruction(let reason) = key.preservation {
      #expect(reason.contains("color-key"))
    } else {
      Issue.record("Color-key masks must be classified as rendered reconstruction")
    }

    let stencil = try ImageOriginalExtraction.extract(
      imageID: PDFObjectID(10), in: parsed.graph)
    if case .renderedReconstruction(let reason) = stencil.preservation {
      #expect(reason.contains("Stencil"))
    } else {
      Issue.record("Stencils must be classified as rendered reconstruction")
    }

    // CMYK stored samples need an explicit color conversion, not a CMYK PNG.
    let cmykSamples = try makeGraph(
      pageContents: [imagesPageContent()], images: [("Im1", cmykImage())])
    let cmykParsed = try PDFParser.parse(PDFWriter.write(cmykSamples))
    let samples = try ImageOriginalExtraction.extract(
      imageID: PDFObjectID(5), in: cmykParsed.graph)
    if case .explicitColorConversion(let reason) = samples.preservation {
      #expect(reason.contains("DeviceCMYK"))
    } else {
      Issue.record("CMYK stored samples must require an explicit conversion")
    }

    // ICCBased bytes keep their profile only in the PDF; extraction must not
    // pretend the standalone JPEG is color-correct.
    let iccProfile = PDFStream(dictionary: [PDFName("N"): .integer(4)], bytes: Data(repeating: 1, count: 16))
    var iccGraph = try makeGraph(
      pageContents: [imagesPageContent()], images: [("Im1", dctImage())])
    iccGraph.objects[PDFObjectID(5)] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Image")),
          PDFName("Width"): .integer(8),
          PDFName("Height"): .integer(8),
          PDFName("ColorSpace"): .array([
            .name(PDFName("ICCBased")), .reference(PDFObjectID(9)),
            .name(PDFName("DeviceCMYK")), .integer(4),
          ]),
          PDFName("BitsPerComponent"): .integer(8),
          PDFName("Filter"): .name(PDFName("DCTDecode")),
        ], bytes: streamBytes(iccGraph, PDFObjectID(5))))
    iccGraph.objects[PDFObjectID(9)] = .stream(iccProfile)
    let iccParsed = try PDFParser.parse(PDFWriter.write(iccGraph))
    let icc = try ImageOriginalExtraction.extract(
      imageID: PDFObjectID(5), in: iccParsed.graph)
    if case .explicitColorConversion(let reason) = icc.preservation {
      #expect(reason.contains("color profile"))
    } else {
      Issue.record("ICCBased JPEG bytes must not claim standalone color preservation")
    }

    // Identity decode keeps the original-samples path.
    let identity = try makeGraph(
      pageContents: [imagesPageContent()], images: [("Im1", rgbImage())])
    var identityDict = streamDictionary(identity, PDFObjectID(5))
    identityDict[PDFName("Decode")] = .array([
      .integer(0), .integer(1), .integer(0), .integer(1), .integer(0), .integer(1),
    ])
    var identityGraph = identity
    identityGraph.objects[PDFObjectID(5)] = .stream(
      PDFStream(dictionary: identityDict, bytes: streamBytes(identity, PDFObjectID(5))))
    let identityParsed = try PDFParser.parse(PDFWriter.write(identityGraph))
    let identityExtracted = try ImageOriginalExtraction.extract(
      imageID: PDFObjectID(5), in: identityParsed.graph)
    if case .originalEncodedBytes(let ext, _) = identityExtracted.preservation {
      #expect(ext == "png")
    } else {
      Issue.record("An identity decode array must not force a conversion")
    }
  }

  // MARK: - Explicit RGB conversion

  @Test func conversionReplacesOneInstanceAndKeepsSharedInstances() throws {
    let (graph, imageID) = try sharedImageGraph(
      pageContent: imagesPageContent(), image: cmykImage())
    let replacement = Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])
    let converted = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceImageInstanceWithConversionCommand(
          pageID: PDFObjectID(3), placementIndex: 0, width: 2, height: 2,
          rgb8: replacement)
      ]), to: graph)
    let page1 = try ImageInventory.placements(in: converted, pageID: PDFObjectID(3))
    let page2 = try ImageInventory.placements(in: converted, pageID: PDFObjectID(4))
    #expect(page1.count == 1)
    #expect(page1[0].imageID != imageID)
    #expect(page2[0].imageID == imageID)
    #expect(page1[0].matrix == page2[0].matrix)
    guard case .stream(let newImage)? = converted.objects[page1[0].imageID] else {
      Issue.record("Converted image is missing")
      return
    }
    #expect(newImage.dictionary[PDFName("ColorSpace")] == .name(PDFName("DeviceRGB")))
    #expect(newImage.dictionary[PDFName("BitsPerComponent")] == .integer(8))
    #expect(try PDFFilters.decoded(newImage) == replacement)
    #expect(converted.objects[imageID] == graph.objects[imageID])
    let reopened = try PDFParser.parse(PDFWriter.write(converted))
    #expect(try ImageInventory.placements(in: reopened.graph, pageID: PDFObjectID(3))[0]
      .imageID == page1[0].imageID)
  }

  @Test func conversionRequiresExplicitTransparencyDecisions() throws {
    var graph = try makeGraph(
      pageContents: [imagesPageContent()], images: [("Im1", rgbImage())])
    var dict = streamDictionary(graph, PDFObjectID(5))
    dict[PDFName("SMask")] = .reference(PDFObjectID(6))
    graph.objects[PDFObjectID(6)] = .stream(grayMaskImage())
    graph.objects[PDFObjectID(5)] = .stream(
      PDFStream(dictionary: dict, bytes: streamBytes(graph, PDFObjectID(5))))
    let parsed = try PDFParser.parse(PDFWriter.write(graph))
    let alpha = Data([0, 64, 128, 255])
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReplaceImageInstanceWithConversionCommand(
            pageID: PDFObjectID(3), placementIndex: 0, width: 2, height: 2,
            rgb8: Data(repeating: 255, count: 12))
        ]), to: parsed.graph)
    }
    let converted = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceImageInstanceWithConversionCommand(
          pageID: PDFObjectID(3), placementIndex: 0, width: 2, height: 2,
          rgb8: Data(repeating: 255, count: 12), alpha8: alpha)
      ]), to: parsed.graph)
    let placement = try #require(
      ImageInventory.placements(in: converted, pageID: PDFObjectID(3)).first)
    guard case .stream(let image)? = converted.objects[placement.imageID],
      case .reference(let maskID)? = image.dictionary[PDFName("SMask")],
      case .stream(let mask)? = converted.objects[maskID]
    else {
      Issue.record("Explicit conversion lost its replacement alpha")
      return
    }
    #expect(try PDFFilters.decoded(mask) == alpha)
    // Explicit discard path drops the old mask on purpose.
    let discarded = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceImageInstanceWithConversionCommand(
          pageID: PDFObjectID(3), placementIndex: 0, width: 2, height: 2,
          rgb8: Data(repeating: 255, count: 12), discardSoftMask: true)
      ]), to: parsed.graph)
    let discardedPlacement = try #require(
      ImageInventory.placements(in: discarded, pageID: PDFObjectID(3)).first)
    guard case .stream(let discardedImage)? = discarded.objects[discardedPlacement.imageID]
    else {
      Issue.record("Explicit discard conversion is missing")
      return
    }
    #expect(discardedImage.dictionary[PDFName("SMask")] == nil)

    var colorKey = try makeGraph(
      pageContents: [imagesPageContent()], images: [("Im1", rgbImage())])
    var keyDict = streamDictionary(colorKey, PDFObjectID(5))
    keyDict[PDFName("Mask")] = .array([.integer(0), .integer(255), .integer(0)])
    colorKey.objects[PDFObjectID(5)] = .stream(
      PDFStream(dictionary: keyDict, bytes: streamBytes(colorKey, PDFObjectID(5))))
    let keyParsed = try PDFParser.parse(PDFWriter.write(colorKey))
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReplaceImageInstanceWithConversionCommand(
            pageID: PDFObjectID(3), placementIndex: 0, width: 2, height: 2,
            rgb8: Data(repeating: 255, count: 12))
        ]), to: keyParsed.graph)
    }
    _ = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceImageInstanceWithConversionCommand(
          pageID: PDFObjectID(3), placementIndex: 0, width: 2, height: 2,
          rgb8: Data(repeating: 255, count: 12), discardColorKeyMask: true)
      ]), to: keyParsed.graph)

    // Stencil images stay on their dedicated path.
    let stencil = try makeGraph(
      pageContents: [imagesPageContent()], images: [("Im1", stencilImage())])
    let stencilParsed = try PDFParser.parse(PDFWriter.write(stencil))
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReplaceImageInstanceWithConversionCommand(
            pageID: PDFObjectID(3), placementIndex: 0, width: 2, height: 2,
            rgb8: Data(repeating: 255, count: 12))
        ]), to: stencilParsed.graph)
    }
  }

  @Test func legacyReplacementCommandsRefuseSilentSoftMaskDrop() throws {
    var graph = try makeGraph(
      pageContents: [imagesPageContent()], images: [("Im1", rgbImage())])
    var dict = streamDictionary(graph, PDFObjectID(5))
    dict[PDFName("SMask")] = .reference(PDFObjectID(6))
    graph.objects[PDFObjectID(6)] = .stream(grayMaskImage())
    graph.objects[PDFObjectID(5)] = .stream(
      PDFStream(dictionary: dict, bytes: streamBytes(graph, PDFObjectID(5))))
    let parsed = try PDFParser.parse(PDFWriter.write(graph))
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReplaceImageDataCommand(
            pageID: PDFObjectID(3), placementIndex: 0, width: 2, height: 2,
            rgb8: Data(repeating: 255, count: 12))
        ]), to: parsed.graph)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReplaceSharedImageCommand(
            pageID: PDFObjectID(3), placementIndex: 0, width: 2, height: 2,
            rgb8: Data(repeating: 255, count: 12))
        ]), to: parsed.graph)
    }
  }

  // MARK: - Codec/color byte preservation across geometry edits

  @Test func geometryEditsPreserveCMYKJPXAndDecodeDictionaries() throws {
    var graph = try makeGraph(
      pageContents: [
        "q 50 0 0 50 100 300 cm /ImCMYK Do Q\nq 50 0 0 50 200 300 cm /ImJPX Do Q\nq 50 0 0 50 300 300 cm /ImDecode Do Q\n"
      ],
      images: [
        ("ImCMYK", dctImage()),
        ("ImJPX", jpxImage()),
        ("ImDecode", rgbImage()),
      ])
    var decodeDict = streamDictionary(graph, PDFObjectID(7))
    decodeDict[PDFName("Decode")] = .array([
      .integer(1), .integer(0), .integer(1), .integer(0), .integer(1), .integer(0),
    ])
    graph.objects[PDFObjectID(7)] = .stream(
      PDFStream(dictionary: decodeDict, bytes: streamBytes(graph, PDFObjectID(7))))
    let parsed = try PDFParser.parse(PDFWriter.write(graph))
    let before = ImageCodecPreservation.imageBytes(in: parsed.graph)
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        MoveImageCommand(pageID: PDFObjectID(3), placementIndex: 0, dx: 10, dy: 10),
        ScaleImageCommand(pageID: PDFObjectID(3), placementIndex: 1, uniformScale: 1.5),
      ]), to: parsed.graph)
    #expect(ImageCodecPreservation.preserved(before: before, after: edited))
    guard case .stream(let cmyk)? = edited.objects[PDFObjectID(5)],
      case .stream(let decode)? = edited.objects[PDFObjectID(7)]
    else {
      Issue.record("Codec image objects are missing")
      return
    }
    #expect(cmyk.dictionary[PDFName("Filter")] == .name(PDFName("DCTDecode")))
    #expect(cmyk.dictionary[PDFName("ColorSpace")] == .name(PDFName("DeviceCMYK")))
    #expect(cmyk.bytes == Data([0xFF, 0xD8, 1, 2, 0xFF, 0xD9]))
    #expect(decode.dictionary[PDFName("Decode")] != nil)
    let reopened = try PDFParser.parse(PDFWriter.write(edited))
    #expect(ImageCodecPreservation.preserved(before: before, after: reopened.graph))
  }

  // MARK: - Capability table

  @Test func capabilityTableCoversColorMaskAndConversionRows() throws {
    #expect(ImageCapabilities.rows.count == 22)
    func row(codec: String, mask: String) throws -> ImageCapabilityRow {
      try #require(ImageCapabilities.rows.first { $0.codec == codec && $0.mask == mask })
    }
    #expect(try row(codec: "DeviceCMYK 8-bit", mask: "none").extract
      == "explicit conversion")
    #expect(try row(codec: "DCTDecode/JPXDecode", mask: "none").extract == "original bytes")
    #expect(try row(codec: "DCTDecode/JPXDecode", mask: "SMask or color-key").extract
      == "explicit conversion")
    #expect(try row(codec: "Any color image", mask: "any").edit == "RGB conversion command")
    #expect(try row(codec: "FlateDecode", mask: "SMask").extract
      == "alpha-preserving PNG")
    #expect(!ImageCapabilities.summary().isEmpty)
  }
}
