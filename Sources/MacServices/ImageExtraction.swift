import CoreGraphics
import Foundation
import ImageIO
import PDFCore
import PDFEditing
import UniformTypeIdentifiers

/// P34-007/P34-008: image extraction with explicit provenance. Standalone
/// JPEG/JPEG 2000 streams are written byte-for-byte; stored RGB/gray samples
/// are wrapped into a PNG without resampling; everything else (masks,
/// transforms, unusual color spaces) is reconstructed by rendering the
/// placement region, and the result says so.
public struct PDFImageExtractionOptions: Sendable, Equatable {
  public var renderDPI: Double

  public init(renderDPI: Double = 144) {
    self.renderDPI = renderDPI
  }
}

public struct PDFExportedImage: Sendable, Equatable {
  public enum Provenance: String, Sendable, Equatable {
    /// The file contains the original encoded bytes or stored samples.
    case original
    /// The file was reconstructed by rendering.
    case reconstructed
  }

  public let pageIndex: Int
  public let name: String
  public let provenance: Provenance
  public let url: URL
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let byteCount: Int
}

public enum PDFImageExport {
  /// Deterministic names: `<base>-page-0001-image-0001.png`.
  public static func filename(
    baseName: String, pageNumber: Int, imageNumber: Int, fileExtension: String
  ) -> String {
    String(
      format: "%@-page-%04d-image-%04d.%@", baseName, pageNumber, imageNumber, fileExtension)
  }

  /// Export every image placement on the given pages. Cancellation is checked
  /// between images.
  public static func export(
    pageIDs: [PDFObjectID], in graph: PDFGraph, to directory: URL, baseName: String,
    options: PDFImageExtractionOptions = .init(), progress: ((Int, Int) -> Void)? = nil
  ) async throws -> [PDFExportedImage] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let images = try PDFImageInventory.images(in: graph, pageIDs: pageIDs)
    var exported: [PDFExportedImage] = []
    var perPageCounts: [Int: Int] = [:]
    for (offset, image) in images.enumerated() {
      try Task.checkCancellation()
      let number = (perPageCounts[image.pageIndex] ?? 0) + 1
      perPageCounts[image.pageIndex] = number
      let encoded = try encodedImage(image, pageIDs: pageIDs, graph: graph, options: options)
      let name = filename(
        baseName: baseName, pageNumber: image.pageIndex + 1, imageNumber: number,
        fileExtension: encoded.fileExtension)
      let url = directory.appendingPathComponent(name)
      try encoded.data.write(to: url, options: .atomic)
      exported.append(
        PDFExportedImage(
          pageIndex: image.pageIndex, name: image.name, provenance: encoded.provenance, url: url,
          pixelWidth: encoded.pixelWidth, pixelHeight: encoded.pixelHeight,
          byteCount: encoded.data.count))
      progress?(offset + 1, images.count)
    }
    return exported
  }

  /// P35-015: resolve one DOCX image request to package bytes. Original
  /// streams and stored samples are used where independently usable;
  /// masked/transformed placements are rendered at the chosen DPI.
  public static func docxResource(
    for request: DOCXImageRequest, pageIDs: [PDFObjectID], in graph: PDFGraph,
    options: PDFImageExtractionOptions = .init()
  ) throws -> DOCXImageResource? {
    // P35-021: an uncertain region is rendered at the chosen DPI.
    if request.isAppearance {
      guard request.pageIndex >= 0, request.pageIndex < pageIDs.count else { return nil }
      let data = try PageImageExport.regionImageData(
        pageID: pageIDs[request.pageIndex], in: graph, region: request.bounds,
        options: PageImageExportOptions(format: .png, dpi: options.renderDPI))
      return DOCXImageResource(data: data, fileExtension: "png", contentType: "image/png")
    }
    let images = try PDFImageInventory.images(in: graph, pageIDs: pageIDs)
    guard
      let image = images.first(where: {
        $0.pageIndex == request.pageIndex && $0.name == request.name
          && $0.bounds == request.bounds
      })
    else { return nil }
    let encoded = try encodedImage(image, pageIDs: pageIDs, graph: graph, options: options)
    return DOCXImageResource(
      data: encoded.data, fileExtension: encoded.fileExtension,
      contentType: contentType(forExtension: encoded.fileExtension))
  }

  static func contentType(forExtension fileExtension: String) -> String {
    switch fileExtension.lowercased() {
    case "jpg", "jpeg": return "image/jpeg"
    case "jp2": return "image/jp2"
    default: return "image/png"
    }
  }

  private struct Encoded {
    let data: Data
    let fileExtension: String
    let provenance: PDFExportedImage.Provenance
    let pixelWidth: Int
    let pixelHeight: Int
  }

  private static func encodedImage(
    _ image: PDFImageResource, pageIDs: [PDFObjectID], graph: PDFGraph,
    options: PDFImageExtractionOptions
  ) throws -> Encoded {
    if image.isStandaloneJPEG {
      return Encoded(
        data: image.encodedData, fileExtension: "jpg", provenance: .original,
        pixelWidth: image.width, pixelHeight: image.height)
    }
    if image.isStandaloneJPEG2000 {
      return Encoded(
        data: image.encodedData, fileExtension: "jp2", provenance: .original,
        pixelWidth: image.width, pixelHeight: image.height)
    }
    if image.isWrappableSamples {
      if let wrapped = try wrapSamples(image) {
        return Encoded(
          data: wrapped, fileExtension: "png", provenance: .original,
          pixelWidth: image.width, pixelHeight: image.height)
      }
    }
    // Reconstruction: render the placement region of the page.
    guard image.pageIndex >= 0, image.pageIndex < pageIDs.count else {
      throw PageImageExport.ExportError.missingPage
    }
    let data = try PageImageExport.regionImageData(
      pageID: pageIDs[image.pageIndex], in: graph, region: image.bounds,
      options: PageImageExportOptions(format: .png, dpi: options.renderDPI))
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw PageImageExport.ExportError.encodingFailed }
    return Encoded(
      data: data, fileExtension: "png", provenance: .reconstructed,
      pixelWidth: cgImage.width, pixelHeight: cgImage.height)
  }

  /// Wrap stored 8-bit RGB/gray samples into a PNG without resampling.
  static func wrapSamples(_ image: PDFImageResource) throws -> Data? {
    guard image.width > 0, image.height > 0 else { return nil }
    var dictionary: [PDFName: PDFValue] = [
      PDFName("Width"): .integer(Int64(image.width)),
      PDFName("Height"): .integer(Int64(image.height)),
      PDFName("BitsPerComponent"): .integer(8),
      PDFName("ColorSpace"): .name(PDFName(image.colorSpace)),
    ]
    if let filter = image.filters.first {
      dictionary[PDFName("Filter")] = .name(PDFName(filter))
    }
    let stream = PDFStream(dictionary: dictionary, bytes: image.encodedData)
    let samples = try PDFFilters.decoded(stream)
    let components = image.colorSpace == "DeviceGray" ? 1 : 3
    guard samples.count >= image.width * image.height * components else { return nil }
    let colorSpace =
      components == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
    // Stored samples carry no alpha channel; 24-bit RGB and 8-bit gray both
    // require the plain none alpha info.
    let alphaInfo: CGImageAlphaInfo = .none
    guard
      let provider = CGDataProvider(data: Data(samples.prefix(image.width * image.height * components)) as CFData),
      let cgImage = CGImage(
        width: image.width, height: image.height, bitsPerComponent: 8,
        bitsPerPixel: 8 * components, bytesPerRow: image.width * components, space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue), provider: provider, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)
    else { return nil }
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }
}
