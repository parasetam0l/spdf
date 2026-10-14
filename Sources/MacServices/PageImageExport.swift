import CoreGraphics
import Foundation
import ImageIO
import PDFCore
import PDFEditing
import UniformTypeIdentifiers

/// P34-003–P34-006/P34-026: page image export through CoreGraphics and
/// ImageIO with explicit resolution, alpha, and color choices. Rendering
/// honors page rotation and the crop box; encoded bytes come from public
/// image codecs only.
public struct PageImageExportOptions: Sendable, Equatable {
  public enum Format: Sendable, Equatable {
    case png
    case jpeg
    case tiff

    var uti: String {
      switch self {
      case .png: return UTType.png.identifier
      case .jpeg: return UTType.jpeg.identifier
      case .tiff: return UTType.tiff.identifier
      }
    }

    public var fileExtension: String {
      switch self {
      case .png: return "png"
      case .jpeg: return "jpg"
      case .tiff: return "tif"
      }
    }
  }

  public enum ColorModel: Sendable, Equatable {
    case rgb
    case gray
  }

  public var format: Format
  public var dpi: Double
  /// When false the page is composited on an opaque white background.
  public var includeAlpha: Bool
  public var colorModel: ColorModel
  public var jpegQuality: Double

  public init(
    format: Format = .png, dpi: Double = 144, includeAlpha: Bool = false,
    colorModel: ColorModel = .rgb, jpegQuality: Double = 0.85
  ) {
    self.format = format
    self.dpi = dpi
    self.includeAlpha = includeAlpha
    self.colorModel = colorModel
    self.jpegQuality = jpegQuality
  }
}

public enum PageImageExport {
  public struct ExportedPage: Sendable, Equatable {
    public let pageIndex: Int
    public let url: URL
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let byteCount: Int
  }

  public enum ExportError: Error {
    case cannotOpenDocument
    case missingPage
    case contextCreationFailed
    case encodingFailed
  }

  /// Deterministic file names: `<base>-<page>.<ext>` with zero padding wide
  /// enough for the document's page count.
  public static func filename(
    baseName: String, pageNumber: Int, pageCount: Int, format: PageImageExportOptions.Format
  ) -> String {
    let digits = max(4, String(max(pageCount, 1)).count)
    let padded = String(format: "%0\(digits)d", pageNumber)
    return "\(baseName)-\(padded).\(format.fileExtension)"
  }

  /// Render one page of the document to encoded image bytes.
  public static func imageData(
    pageID: PDFObjectID, in graph: PDFGraph, options: PageImageExportOptions = .init()
  ) throws -> Data {
    let document = try openDocument(graph)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    guard let index = pageIDs.firstIndex(of: pageID), let page = document.page(at: index + 1) else {
      throw ExportError.missingPage
    }
    return try encode(page: page, options: options).data
  }

  /// Batch export to a directory, checking cancellation between pages.
  public static func export(
    pages: [PDFObjectID], in graph: PDFGraph, to directory: URL, baseName: String,
    options: PageImageExportOptions = .init(), progress: ((Int, Int) -> Void)? = nil
  ) async throws -> [ExportedPage] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let document = try openDocument(graph)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    var exported: [ExportedPage] = []
    for (offset, pageID) in pages.enumerated() {
      try Task.checkCancellation()
      guard let index = pageIDs.firstIndex(of: pageID), let page = document.page(at: index + 1)
      else { throw ExportError.missingPage }
      let encoded = try encode(page: page, options: options)
      try Task.checkCancellation()
      let name = filename(
        baseName: baseName, pageNumber: index + 1, pageCount: pageIDs.count, format: options.format)
      let url = directory.appendingPathComponent(name)
      try encoded.data.write(to: url, options: .atomic)
      exported.append(
        ExportedPage(
          pageIndex: index, url: url, pixelWidth: encoded.width, pixelHeight: encoded.height,
          byteCount: encoded.data.count))
      progress?(offset + 1, pages.count)
    }
    try Task.checkCancellation()
    return exported
  }

  /// Pixel buffer bytes a page needs at the given options (used for bounds).
  public static func bufferBytes(
    pageID: PDFObjectID, in graph: PDFGraph, options: PageImageExportOptions = .init()
  ) throws -> Int {
    let document = try openDocument(graph)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    guard let index = pageIDs.firstIndex(of: pageID), let page = document.page(at: index + 1) else {
      throw ExportError.missingPage
    }
    let (width, height) = pixelSize(of: page, options: options)
    let samples = options.colorModel == .gray ? 1 : 4
    return width * height * samples
  }

  // MARK: - Internals

  private struct Encoded {
    let data: Data
    let width: Int
    let height: Int
  }

  private static func openDocument(_ graph: PDFGraph) throws -> CGPDFDocument {
    let bytes = try PDFWriter.write(graph)
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
      let document = CGPDFDocument(provider)
    else { throw ExportError.cannotOpenDocument }
    return document
  }

  /// The page box as displayed: /Rotate 90 and 270 swap width and height, and
  /// the drawing transform below maps the content into this rotated box.
  static func displayBox(of page: CGPDFPage) -> CGRect {
    var box = page.getBoxRect(.cropBox)
    if box.isEmpty { box = page.getBoxRect(.mediaBox) }
    let rotation = ((page.rotationAngle % 360) + 360) % 360
    if rotation == 90 || rotation == 270 {
      box = CGRect(x: box.origin.x, y: box.origin.y, width: box.height, height: box.width)
    }
    return box
  }

  private static func pixelSize(of page: CGPDFPage, options: PageImageExportOptions)
    -> (Int, Int)
  {
    let box = displayBox(of: page)
    let scale = max(1, options.dpi) / 72
    return (max(1, Int((box.width * scale).rounded())),
            max(1, Int((box.height * scale).rounded())))
  }

  /// Render the whole page to a CGImage at the requested options.
  static func renderImage(page: CGPDFPage, options: PageImageExportOptions) throws -> CGImage {
    let box = displayBox(of: page)
    let scale = max(1, options.dpi) / 72
    let (width, height) = pixelSize(of: page, options: options)
    let gray = options.colorModel == .gray
    let colorSpace = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
    // Grayscale contexts are always opaque; RGB honors the alpha policy.
    let alphaInfo: CGImageAlphaInfo = gray ? .none : (options.includeAlpha ? .premultipliedLast : .noneSkipLast)
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: colorSpace, bitmapInfo: alphaInfo.rawValue)
    else { throw ExportError.contextCreationFailed }
    context.interpolationQuality = .high
    if alphaInfo == .none || alphaInfo == .noneSkipLast {
      context.setFillColor(gray ? CGColor(gray: 1, alpha: 1) : CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    context.saveGState()
    context.scaleBy(x: scale, y: scale)
    let target = CGRect(x: 0, y: 0, width: box.width, height: box.height)
    context.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
    context.drawPDFPage(page)
    context.restoreGState()
    guard let image = context.makeImage() else { throw ExportError.contextCreationFailed }
    return image
  }

  /// Render one region (in unrotated page content space) and encode it. Used
  /// for figures and previews; rotation is handled through the page's drawing
  /// transform before cropping.
  public static func regionImageData(
    pageID: PDFObjectID, in graph: PDFGraph, region: [Double],
    options: PageImageExportOptions = .init()
  ) throws -> Data {
    let document = try openDocument(graph)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    guard let index = pageIDs.firstIndex(of: pageID), let page = document.page(at: index + 1) else {
      throw ExportError.missingPage
    }
    let image = try renderImage(page: page, options: options)
    guard region.count == 4 else { return try encode(image: image, options: options) }
    let box = displayBox(of: page)
    let scale = max(1, options.dpi) / 72
    let target = CGRect(x: 0, y: 0, width: box.width, height: box.height)
    let transform = page.getDrawingTransform(
      .cropBox, rect: target, rotate: 0, preserveAspectRatio: true)
    var minX = Double.greatestFiniteMagnitude
    var minY = Double.greatestFiniteMagnitude
    var maxX = -Double.greatestFiniteMagnitude
    var maxY = -Double.greatestFiniteMagnitude
    for (x, y) in [
      (region[0], region[1]), (region[2], region[1]), (region[0], region[3]), (region[2], region[3]),
    ] {
      let point = CGPoint(x: x, y: y).applying(transform)
      minX = min(minX, point.x * scale)
      minY = min(minY, point.y * scale)
      maxX = max(maxX, point.x * scale)
      maxY = max(maxY, point.y * scale)
    }
    let crop = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
      .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard !crop.isNull, crop.width >= 1, crop.height >= 1 else {
      return try encode(image: image, options: options)
    }
    // CGImage cropping uses a top-left origin; the context is bottom-left.
    let topLeft = CGRect(
      x: crop.origin.x, y: CGFloat(image.height) - crop.maxY, width: crop.width,
      height: crop.height)
    guard let cropped = image.cropping(to: topLeft) else {
      return try encode(image: image, options: options)
    }
    return try encode(image: cropped, options: options)
  }

  /// P03-025: a reproducible page-render snapshot — the PNG bytes plus
  /// metadata naming the renderer, OS, scale, and page size. PNG encoding
  /// carries no timestamps, so the same document renders byte-identically
  /// on one machine and renderer; cross-machine comparison stays a
  /// tolerance-based visual diff (P03-026), never a byte assertion.
  public struct RenderSnapshot: Sendable, Equatable {
    public let png: Data
    public let metadata: [String: String]
  }

  public static func snapshot(
    pageID: PDFObjectID, in graph: PDFGraph, scale: Double = 1
  ) throws -> RenderSnapshot {
    let document = try openDocument(graph)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    guard let index = pageIDs.firstIndex(of: pageID), let page = document.page(at: index + 1)
    else { throw ExportError.missingPage }
    let options = PageImageExportOptions(format: .png, dpi: 72 * max(0.02, scale))
    let encoded = try encode(page: page, options: options)
    let box = displayBox(of: page)
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return RenderSnapshot(
      png: encoded.data,
      metadata: [
        "renderer": "CoreGraphics",
        "os": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
        "scale": String(scale),
        "pageWidth": String(format: "%.2f", box.width),
        "pageHeight": String(format: "%.2f", box.height),
        "pixels": "\(encoded.width)x\(encoded.height)",
      ])
  }

  private static func encode(page: CGPDFPage, options: PageImageExportOptions) throws -> Encoded {
    let image = try renderImage(page: page, options: options)
    let data = try encode(image: image, options: options)
    let (width, height) = pixelSize(of: page, options: options)
    return Encoded(data: data, width: width, height: height)
  }

  private static func encode(image: CGImage, options: PageImageExportOptions) throws -> Data {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, options.format.uti as CFString, 1, nil)
    else { throw ExportError.encodingFailed }
    var properties: [CFString: Any] = [:]
    switch options.format {
    case .png:
      properties[kCGImagePropertyPNGDictionary] = [:] as CFDictionary
    case .jpeg:
      properties[kCGImageDestinationLossyCompressionQuality] = min(max(options.jpegQuality, 0), 1)
    case .tiff:
      properties[kCGImagePropertyTIFFDictionary] = [
        kCGImagePropertyTIFFCompression: 5  // LZW
      ] as CFDictionary
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw ExportError.encodingFailed }
    return data as Data
  }
}
