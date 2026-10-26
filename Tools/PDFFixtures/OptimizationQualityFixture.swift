import Foundation
import PDFCore

/// PRE-09 harness fixture: one page with a large DeviceRGB image (1200x900
/// samples) placed at 100x75 pt, so effective resolution is far above print/web
/// targets and downsampling is measurable.
public enum OptimizationQualityFixture {
  public static func largeRGBImagePages(width: Int = 1200, height: Int = 900) throws -> Data {
    var pixels = [UInt8](repeating: 0, count: width * height * 3)
    var index = 0
    for y in 0..<height {
      for x in 0..<width {
        pixels[index] = UInt8((x * 255) / max(width - 1, 1))
        pixels[index + 1] = UInt8((y * 255) / max(height - 1, 1))
        pixels[index + 2] = UInt8(((x + y) * 255) / max(width + height - 2, 1))
        index += 3
      }
    }
    let encoded = try PDFFilters.encodeFlate(Data(pixels))
    let content = "q 100 0 0 75 100 300 cm /Im1 Do Q\n"
    let graph = PDFGraph(objects: [
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
          PDFName("XObject"): .dictionary([PDFName("Im1"): .reference(PDFObjectID(5))])
        ]),
        PDFName("Contents"): .reference(PDFObjectID(4)),
      ]),
      PDFObjectID(4): .stream(PDFStream(bytes: Data(content.utf8))),
      PDFObjectID(5): .stream(
        PDFStream(
          dictionary: [
            PDFName("Type"): .name(PDFName("XObject")),
            PDFName("Subtype"): .name(PDFName("Image")),
            PDFName("Width"): .integer(Int64(width)),
            PDFName("Height"): .integer(Int64(height)),
            PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
            PDFName("BitsPerComponent"): .integer(8),
            PDFName("Filter"): .name(PDFName("FlateDecode")),
          ], bytes: encoded)),
    ], trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    return try PDFWriter.write(graph)
  }
}

