import CoreGraphics
import Foundation
import ImageIO
import PDFCore
import PDFEditing
import Testing
import UniformTypeIdentifiers
@testable import MacServices

/// P34-007/P34-008: original-bytes extraction when encoded data is
/// independently usable, stored-sample wrapping without resampling, and
/// rendered reconstruction for masked images, with explicit provenance.
@Suite("Image extraction")
struct ImageExtractionTests {
  private func jpegData(width: Int = 8, height: Int = 8) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for index in stride(from: 0, to: pixels.count, by: 4) {
      pixels[index] = 255
      pixels[index + 1] = 128
      pixels[index + 2] = 0
      pixels[index + 3] = 255
    }
    guard
      let provider = CGDataProvider(data: Data(pixels) as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { throw PageImageExport.ExportError.contextCreationFailed }
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw PageImageExport.ExportError.encodingFailed }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw PageImageExport.ExportError.encodingFailed
    }
    return data as Data
  }

  private func fixture(jpeg: Data) -> PDFGraph {
    let green = Data([0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0])
    let pageOne = """
      q 100 0 0 100 50 600 cm /ImJ Do Q
      q 120 0 0 120 200 600 cm /ImR Do Q
      q 100 0 0 100 350 600 cm /ImM Do Q

      """
    let pageTwo = """
      q 120 0 0 120 50 400 cm /ImR Do Q

      """
    return PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(2),
          PDFName("Kids"): .array([.reference(PDFObjectID(4)), .reference(PDFObjectID(6))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("XObject"): .dictionary([
              PDFName("ImJ"): .reference(PDFObjectID(20)),
              PDFName("ImR"): .reference(PDFObjectID(21)),
              PDFName("ImM"): .reference(PDFObjectID(22)),
            ])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(pageOne.utf8))),
        PDFObjectID(6): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("XObject"): .dictionary([PDFName("ImR"): .reference(PDFObjectID(21))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(7)),
        ]),
        PDFObjectID(7): .stream(PDFStream(bytes: Data(pageTwo.utf8))),
        PDFObjectID(20): .stream(
          PDFStream(
            dictionary: [
              PDFName("Type"): .name(PDFName("XObject")),
              PDFName("Subtype"): .name(PDFName("Image")),
              PDFName("Width"): .integer(8), PDFName("Height"): .integer(8),
              PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
              PDFName("BitsPerComponent"): .integer(8),
              PDFName("Filter"): .name(PDFName("DCTDecode")),
            ], bytes: jpeg)),
        PDFObjectID(21): .stream(
          PDFStream(
            dictionary: [
              PDFName("Type"): .name(PDFName("XObject")),
              PDFName("Subtype"): .name(PDFName("Image")),
              PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
              PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
              PDFName("BitsPerComponent"): .integer(8),
            ], bytes: green)),
        PDFObjectID(22): .stream(
          PDFStream(
            dictionary: [
              PDFName("Type"): .name(PDFName("XObject")),
              PDFName("Subtype"): .name(PDFName("Image")),
              PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
              PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
              PDFName("BitsPerComponent"): .integer(8),
              PDFName("SMask"): .reference(PDFObjectID(23)),
            ], bytes: green)),
        PDFObjectID(23): .stream(
          PDFStream(
            dictionary: [
              PDFName("Type"): .name(PDFName("XObject")),
              PDFName("Subtype"): .name(PDFName("Image")),
              PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
              PDFName("ColorSpace"): .name(PDFName("DeviceGray")),
              PDFName("BitsPerComponent"): .integer(8),
            ], bytes: Data([255, 255, 255, 255]))),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  /// P35-015: DOCX image requests resolve to original bytes or rendered
  /// reconstructions, and the packaged document embeds them.
  @Test func docxImageRequestsResolveToOriginalOrRenderedBytes() throws {
    let jpeg = try jpegData()
    let graph = fixture(jpeg: jpeg)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let reconstruction = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: pageIDs, in: graph)
    let requests = reconstruction.blocks.compactMap { block -> DOCXImageRequest? in
      if case .image(let request) = block.kind { return request } else { return nil }
    }
    #expect(requests.count == 4)

    // A standalone JPEG keeps its original bytes.
    let jpegRequest = try #require(requests.first { $0.name == "ImJ" })
    let jpegResource = try #require(
      try PDFImageExport.docxResource(for: jpegRequest, pageIDs: pageIDs, in: graph))
    #expect(jpegResource.fileExtension == "jpg")
    #expect(jpegResource.contentType == "image/jpeg")
    #expect(jpegResource.data == jpeg)

    // Stored samples wrap into PNG without resampling.
    let samplesRequest = try #require(requests.first { $0.name == "ImR" && $0.pageIndex == 0 })
    let samplesResource = try #require(
      try PDFImageExport.docxResource(for: samplesRequest, pageIDs: pageIDs, in: graph))
    #expect(samplesResource.fileExtension == "png")
    #expect(samplesResource.contentType == "image/png")
    #expect(
      samplesResource.data.prefix(8)
        == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

    // A masked image is reconstructed by rendering.
    let maskedRequest = try #require(requests.first { $0.name == "ImM" })
    let maskedResource = try #require(
      try PDFImageExport.docxResource(for: maskedRequest, pageIDs: pageIDs, in: graph))
    #expect(maskedResource.fileExtension == "png")

    // An unknown request resolves to nil rather than a guess.
    let unknown = DOCXImageRequest(pageIndex: 0, name: "Missing", bounds: [0, 0, 1, 1])
    #expect(try PDFImageExport.docxResource(for: unknown, pageIDs: pageIDs, in: graph) == nil)

    // P35-021: an appearance region is rendered, not looked up.
    let region = DOCXImageRequest(
      pageIndex: 0, name: "appearance", bounds: [50, 600, 150, 700], isAppearance: true)
    let regionResource = try #require(
      try PDFImageExport.docxResource(for: region, pageIDs: pageIDs, in: graph))
    #expect(regionResource.fileExtension == "png")
    #expect(regionResource.contentType == "image/png")
    #expect(
      regionResource.data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    let outOfRange = DOCXImageRequest(
      pageIndex: 9, name: "appearance", bounds: [0, 0, 10, 10], isAppearance: true)
    #expect(try PDFImageExport.docxResource(for: outOfRange, pageIDs: pageIDs, in: graph) == nil)

    // The packaged DOCX embeds the resolved media with relationships.
    let data = try DOCXExport.package(
      reconstruction: reconstruction,
      imageResolver: { request in
        try? PDFImageExport.docxResource(for: request, pageIDs: pageIDs, in: graph)
      })
    let listing = String(decoding: data, as: UTF8.self)
    #expect(listing.contains("word/media/image0001.png"))
    #expect(listing.contains("word/media/image0002.jpg"))
  }

  @Test func inventoryClassifiesUsability() throws {
    let graph = fixture(jpeg: try jpegData())
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let images = try PDFImageInventory.images(in: graph, pageIDs: pageIDs)
    #expect(images.count == 4)
    let jpeg = try #require(images.first { $0.name == "ImJ" })
    #expect(jpeg.isStandaloneJPEG && jpeg.hasUsableOriginal)
    #expect(jpeg.width == 8 && jpeg.height == 8)
    let raw = try #require(images.first { $0.name == "ImR" && $0.pageIndex == 0 })
    #expect(raw.isWrappableSamples && raw.hasUsableOriginal)
    #expect(raw.width == 2 && raw.height == 2)
    let masked = try #require(images.first { $0.name == "ImM" })
    #expect(masked.hasSMask && !masked.hasUsableOriginal)
    #expect(images.filter { $0.name == "ImR" }.count == 2)
  }

  @Test func originalBytesPreservedForStandaloneJPEG() async throws {
    let jpeg = try jpegData()
    let graph = fixture(jpeg: jpeg)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-images-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let exported = try await PDFImageExport.export(
      pageIDs: pageIDs, in: graph, to: directory, baseName: "doc")
    let jpegFile = try #require(exported.first { $0.name == "ImJ" })
    #expect(jpegFile.provenance == .original)
    #expect(jpegFile.url.lastPathComponent == "doc-page-0001-image-0001.jpg")
    // Byte-for-byte preservation of the embedded JPEG stream.
    #expect(try Data(contentsOf: jpegFile.url) == jpeg)
    guard let source = CGImageSourceCreateWithData(try Data(contentsOf: jpegFile.url) as CFData, nil)
    else {
      Issue.record("The extracted JPEG did not reopen")
      return
    }
    #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
  }

  @Test func storedSamplesWrapIntoPNGWithoutResampling() async throws {
    let graph = fixture(jpeg: try jpegData())
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-images-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let exported = try await PDFImageExport.export(
      pageIDs: pageIDs, in: graph, to: directory, baseName: "doc")
    let raw = try #require(exported.first { $0.name == "ImR" && $0.pageIndex == 0 })
    #expect(raw.provenance == .original)
    // The stored samples are 2x2; wrapping must not resample them.
    #expect(raw.pixelWidth == 2 && raw.pixelHeight == 2)
    guard let source = CGImageSourceCreateWithData(try Data(contentsOf: raw.url) as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      Issue.record("The wrapped PNG did not reopen")
      return
    }
    #expect(image.width == 2 && image.height == 2)
    // The fixture's pixels are green.
    if let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
      #expect(bytes[0] == 0 && bytes[1] == 255 && bytes[2] == 0)
    }
  }

  @Test func maskedImagesUseRenderedReconstruction() async throws {
    let graph = fixture(jpeg: try jpegData())
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-images-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let exported = try await PDFImageExport.export(
      pageIDs: pageIDs, in: graph, to: directory, baseName: "doc",
      options: PDFImageExtractionOptions(renderDPI: 144))
    let masked = try #require(exported.first { $0.name == "ImM" })
    #expect(masked.provenance == .reconstructed)
    // The placement is 100x100 points; at 144 dpi that is 200x200 pixels.
    #expect(masked.pixelWidth == 200 && masked.pixelHeight == 200)
    #expect(masked.url.lastPathComponent == "doc-page-0001-image-0003.png")
  }

  @Test func deterministicNamesAndCancellation() async throws {
    let graph = fixture(jpeg: try jpegData())
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-images-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let exported = try await PDFImageExport.export(
      pageIDs: pageIDs, in: graph, to: directory, baseName: "doc")
    #expect(
      exported.map { $0.url.lastPathComponent } == [
        "doc-page-0001-image-0001.jpg", "doc-page-0001-image-0002.png",
        "doc-page-0001-image-0003.png", "doc-page-0002-image-0001.png",
      ])

    let cancelDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-images-cancel-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: cancelDirectory) }
    let task = Task {
      try await PDFImageExport.export(
        pageIDs: pageIDs, in: graph, to: cancelDirectory, baseName: "cancel")
    }
    task.cancel()
    let start = ContinuousClock.now
    let result = await task.result
    let latency = ContinuousClock.now - start
    switch result {
    case .success(let images):
      #expect(images.count == 4)
    case .failure(let error):
      #expect(error is CancellationError)
    }
    #expect(latency < .seconds(2))
  }
}
