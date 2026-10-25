import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import MacServices
import PDFCore
import PDFEditing
import PDFKit
import Testing

/// OCR-04/OCR-05 shared fixture builder: a synthetic scan page with one
/// uniformly scaled image draw, optional skew/background variation and word
/// positions that match a generated searchable layer.
enum ScanTestSupport {
  static let pageSize = CGSize(width: 612, height: 792)
  /// Uniform square image placement inside the page, page coordinates.
  static let pageImageRect = CGRect(x: 0, y: 90, width: 612, height: 612)

  struct ScanLine {
    let text: String
    let baseline: Double
    let x: Double
  }

  /// Draw a synthetic scan raster. Words are drawn at the same offsets the
  /// generated OCR layer geometry uses, so word boxes and pixels align.
  static func raster(
    lines: [ScanLine], width: Int = 600, height: Int = 600,
    fontSizePage: Double = 30, skewDegrees: Double = 0,
    background: UInt8 = 232, backgroundNoise: UInt8 = 0,
    darkInkAround: (x: Int, y: Int, radius: Int)? = nil
  ) throws -> ScanRaster {
    var bytes = Data(count: width * height * 3)
    for index in stride(from: 0, to: bytes.count, by: 3) {
      bytes[index] = background
      bytes[index + 1] = background
      bytes[index + 2] = min(255, background + UInt8(2))
    }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var pixels = Data(count: width * height * 4)
    let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
      guard let base = buffer.baseAddress,
        let context = CGContext(
          data: base, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.interpolationQuality = .none
      context.setFillColor(
        CGColor(
          red: CGFloat(background) / 255, green: CGFloat(background) / 255,
          blue: CGFloat(min(255, background + 2)) / 255, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      let scale = Double(height) / Double(pageImageRect.height)
      context.saveGState()
      context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
      context.rotate(by: CGFloat(skewDegrees * .pi / 180))
      context.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
      let font = CTFontCreateWithName(
        "Helvetica" as CFString, CGFloat(fontSizePage * scale), nil)
      for line in lines {
        let parts = line.text.split(separator: " ", omittingEmptySubsequences: false)
        var offset = 0
        for part in parts {
          if !part.isEmpty {
            let pageX = line.x + Double(offset) * fontSizePage
            let pixelX = (pageX - Double(pageImageRect.minX)) * scale
            let pixelBaseline = (line.baseline - Double(pageImageRect.minY)) * scale
            let attributes: [NSAttributedString.Key: Any] = [
              NSAttributedString.Key(kCTFontAttributeName as String): font,
              NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(red: 0.09, green: 0.09, blue: 0.1, alpha: 1),
            ]
            let attributed = NSAttributedString(
              string: String(part), attributes: attributes)
            let lineRef = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: pixelX, y: pixelBaseline)
            CTLineDraw(lineRef, context)
          }
          offset += part.count + 1
        }
      }
      context.restoreGState()
      return true
    }
    guard drawn else {
      throw PDFError(.malformed, "The synthetic scan could not be drawn")
    }
    var rgb = Data(capacity: width * height * 3)
    for offset in stride(from: 0, to: pixels.count, by: 4) {
      rgb.append(pixels[offset])
      rgb.append(pixels[offset + 1])
      rgb.append(pixels[offset + 2])
    }
    var raster = try ScanRaster(width: width, height: height, rgb8: rgb)
    if backgroundNoise > 0 {
      var state: UInt64 = 0x9E37_79B9_7F4A_7C15
      for y in 0..<height {
        for x in 0..<width {
          state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
          let noise = UInt8(state >> 56) % (backgroundNoise + 1)
          let (r, g, b) = raster.pixel(x: x, y: y)
          if max(r, max(g, b)) < 200 { continue }
          let red = UInt8(min(255, Int(r) + Int(noise)))
          let green = UInt8(min(255, Int(g) + Int(noise)))
          let blue = UInt8(min(255, Int(b) + Int(noise)))
          raster.setPixel(x: x, y: y, r: red, g: green, b: blue)
        }
      }
    }
    if let dark = darkInkAround {
      for y in max(0, dark.y - dark.radius)..<min(height, dark.y + dark.radius) {
        for x in max(0, dark.x - dark.radius)..<min(width, dark.x + dark.radius) {
          raster.setPixel(x: x, y: y, r: 20, g: 20, b: 22)
        }
      }
    }
    return raster
  }

  /// Build a graph whose page draws one uniformly scaled scan image.
  static func graph(
    scans: [ScanRaster], pageImageRect: CGRect = pageImageRect,
    pageSize: CGSize = pageSize
  ) throws -> (graph: PDFGraph, pageIDs: [PDFObjectID], imageIDs: [PDFObjectID]) {
    var objects: [PDFObjectID: PDFValue] = [:]
    let catalogID = PDFObjectID(1)
    let pagesID = PDFObjectID(2)
    var pageIDs: [PDFObjectID] = []
    var imageIDs: [PDFObjectID] = []
    var next = 3
    for scan in scans {
      let pageID = PDFObjectID(next); next += 1
      let contentID = PDFObjectID(next); next += 1
      let imageID = PDFObjectID(next); next += 1
      let imageBytes = scan.rgb8
      objects[imageID] = .stream(
        PDFStream(
          dictionary: [
            PDFName("Type"): .name(PDFName("XObject")),
            PDFName("Subtype"): .name(PDFName("Image")),
            PDFName("Width"): .integer(Int64(scan.width)),
            PDFName("Height"): .integer(Int64(scan.height)),
            PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
            PDFName("BitsPerComponent"): .integer(8),
            PDFName("Length"): .integer(Int64(imageBytes.count)),
          ], bytes: imageBytes))
      let content = "q \(number(pageImageRect.width)) 0 0 \(number(pageImageRect.height)) "
        + "\(number(pageImageRect.minX)) \(number(pageImageRect.minY)) cm /Im1 Do Q\n"
      let contentBytes = Data(content.utf8)
      objects[contentID] = .stream(
        PDFStream(
          dictionary: [PDFName("Length"): .integer(Int64(contentBytes.count))],
          bytes: contentBytes))
      objects[pageID] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(pagesID),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(Int64(pageSize.width)),
          .integer(Int64(pageSize.height)),
        ]),
        PDFName("Contents"): .reference(contentID),
        PDFName("Resources"): .dictionary([
          PDFName("XObject"): .dictionary([PDFName("Im1"): .reference(imageID)])
        ]),
      ])
      pageIDs.append(pageID)
      imageIDs.append(imageID)
    }
    objects[catalogID] = .dictionary([
      PDFName("Type"): .name(PDFName("Catalog")),
      PDFName("Pages"): .reference(pagesID),
    ])
    objects[pagesID] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Kids"): .array(pageIDs.map { .reference($0) }),
      PDFName("Count"): .integer(Int64(pageIDs.count)),
    ])
    let trailer: [PDFName: PDFValue] = [
      PDFName("Root"): .reference(catalogID),
      PDFName("Size"): .integer(Int64(next)),
    ]
    return (PDFGraph(objects: objects, trailer: trailer), pageIDs, imageIDs)
  }

  /// JPEG-encode a raster so the cleanup profile must use the ImageIO path.
  static func jpegData(_ raster: ScanRaster, quality: Double = 0.85) throws -> Data {
    guard let image = raster.cgImage() else {
      throw PDFError(.malformed, "The synthetic scan could not be encoded")
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data, "public.jpeg" as CFString, 1, nil)
    else {
      throw PDFError(.malformed, "The JPEG destination is unavailable")
    }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw PDFError(.malformed, "The synthetic JPEG scan could not be encoded")
    }
    return data as Data
  }

  /// Like graph(scans:) but the image is stored as DCTDecode (JPEG), the usual
  /// real scanner codec.
  static func jpegGraph(
    scans: [ScanRaster], pageImageRect: CGRect = pageImageRect,
    pageSize: CGSize = pageSize
  ) throws -> (graph: PDFGraph, pageIDs: [PDFObjectID], imageIDs: [PDFObjectID]) {
    let built = try graph(
      scans: scans, pageImageRect: pageImageRect, pageSize: pageSize)
    var graph = built.graph
    for (index, imageID) in built.imageIDs.enumerated() {
      let encoded = try jpegData(scans[index])
      guard case .stream(let stream)? = graph.objects[imageID] else { continue }
      var dictionary = stream.dictionary
      dictionary[PDFName("Filter")] = .name(PDFName("DCTDecode"))
      dictionary[PDFName("ColorSpace")] = .name(PDFName("DeviceRGB"))
      dictionary[PDFName("Length")] = .integer(Int64(encoded.count))
      graph.objects[imageID] = .stream(
        PDFStream(dictionary: dictionary, bytes: encoded))
    }
    return (graph, built.pageIDs, built.imageIDs)
  }

  /// Build one page that draws two images side by side (ambiguous scan).
  static func ambiguousGraph(first: ScanRaster, second: ScanRaster) throws -> PDFGraph {
    let catalogID = PDFObjectID(1)
    let pagesID = PDFObjectID(2)
    let pageID = PDFObjectID(3)
    let contentID = PDFObjectID(4)
    let firstID = PDFObjectID(5)
    let secondID = PDFObjectID(6)
    func image(_ raster: ScanRaster) -> PDFValue {
      .stream(
        PDFStream(
          dictionary: [
            PDFName("Type"): .name(PDFName("XObject")),
            PDFName("Subtype"): .name(PDFName("Image")),
            PDFName("Width"): .integer(Int64(raster.width)),
            PDFName("Height"): .integer(Int64(raster.height)),
            PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
            PDFName("BitsPerComponent"): .integer(8),
            PDFName("Length"): .integer(Int64(raster.rgb8.count)),
          ], bytes: raster.rgb8))
    }
    let content = "q 300 0 0 300 6 246 cm /Im1 Do Q\n"
      + "q 300 0 0 300 306 246 cm /Im2 Do Q\n"
    let contentBytes = Data(content.utf8)
    let objects: [PDFObjectID: PDFValue] = [
      catalogID: .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(pagesID),
      ]),
      pagesID: .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Kids"): .array([.reference(pageID)]),
        PDFName("Count"): .integer(1),
      ]),
      pageID: .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(pagesID),
        PDFName("MediaBox"): .array([.integer(0), .integer(0), .integer(612), .integer(792)]),
        PDFName("Contents"): .reference(contentID),
        PDFName("Resources"): .dictionary([
          PDFName("XObject"): .dictionary([
            PDFName("Im1"): .reference(firstID),
            PDFName("Im2"): .reference(secondID),
          ])
        ]),
      ]),
      contentID: .stream(
        PDFStream(
          dictionary: [PDFName("Length"): .integer(Int64(contentBytes.count))],
          bytes: contentBytes)),
      firstID: image(first),
      secondID: image(second),
    ]
    return PDFGraph(
      objects: objects,
      trailer: [
        PDFName("Root"): .reference(catalogID), PDFName("Size"): .integer(7),
      ])
  }

  /// Add a generated searchable layer with line boxes matching the raster
  /// word offsets used by the fixture builder.
  static func addOCRLayer(
    to graph: inout PDFGraph, pageID: PDFObjectID, lines: [ScanLine],
    fontSizePage: Double = 30
  ) throws {
    let searchable = lines.map { line in
      SearchableTextLine(
        text: line.text,
        rect: [line.x, line.baseline, line.x + Double(line.text.count) * fontSizePage,
          line.baseline + fontSizePage])
    }
    graph = try AddSearchableTextLayerCommand(pageID: pageID, lines: searchable)
      .apply(to: graph)
  }

  static func savedBytes(_ graph: PDFGraph) throws -> Data {
    try PDFWriter.write(graph)
  }

  static func reopened(_ graph: PDFGraph) throws -> PDFGraph {
    try PDFParser.parse(try PDFWriter.write(graph)).graph
  }

  static func firstRaster(pageID: PDFObjectID, in graph: PDFGraph) throws -> ScanRaster {
    let placements = try ImageInventory.placements(in: graph, pageID: pageID)
    guard let first = placements.first else {
      throw PDFError(.malformed, "The fixture has no scan image")
    }
    return try ScanImageRaster.raster(imageID: first.imageID, in: graph)
  }

  static func pageText(_ graph: PDFGraph, pageIndex: Int = 0) throws -> String {
    let data = try PDFWriter.write(graph)
    guard let document = PDFDocument(data: data), let page = document.page(at: pageIndex)
    else { return "" }
    return page.string ?? ""
  }

  static func number(_ value: CGFloat) -> String {
    let double = Double(value)
    if double == double.rounded() { return String(Int(double)) }
    return String(double)
  }

  static func inkFraction(_ raster: ScanRaster, rect: CGRect) -> Double {
    let area = max(1, Int(rect.width * rect.height))
    return Double(ScanInkAnalysis.inkPixelCount(raster, region: rect)) / Double(area)
  }
}
