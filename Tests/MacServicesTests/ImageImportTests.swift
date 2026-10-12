import CoreGraphics
import Foundation
import ImageIO
import MacServices
import Testing

/// P20-009/P20-010/P20-011 evidence: raster import through ImageIO with EXIF
/// orientation normalization and explicit DeviceRGB conversion.
@Suite("Image import")
struct ImageImportTests {
  @Test func importsPNGAsRGB() throws {
    let data = try pngData(width: 4, height: 2) { context in
      context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
      context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
      context.fill(CGRect(x: 2, y: 0, width: 2, height: 2))
    }
    let raster = try #require(ImageImport.decode(data))
    #expect(raster.width == 4 && raster.height == 2)
    #expect(raster.rgb8.count == 4 * 2 * 3)
    let bytes = [UInt8](raster.rgb8)
    #expect(bytes[0] > 200 && bytes[1] < 60 && bytes[2] < 60)
    let lastPixel = (raster.width - 1) * 3
    #expect(bytes[lastPixel] < 60 && bytes[lastPixel + 1] < 60 && bytes[lastPixel + 2] > 200)
  }

  @Test func normalizesEXIFOrientation() throws {
    // A 4×2 image tagged orientation 6 (rotate 90° clockwise when displayed)
    // must import as 2×4.
    let source = try jpegData(width: 4, height: 2, orientation: 6) { context in
      context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
    }
    let raster = try #require(ImageImport.decode(source))
    #expect(raster.width == 2 && raster.height == 4)
    let bytes = [UInt8](raster.rgb8)
    #expect(bytes[1] > 200 && bytes[0] < 60 && bytes[2] < 60)
  }

  @Test func convertsGrayscaleAndCompositesTransparency() throws {
    // Grayscale converts explicitly to DeviceRGB.
    let gray = try pngData(
      width: 2, height: 2, colorSpace: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) { context in
      context.setFillColor(CGColor(gray: 0.25, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }
    let grayRaster = try #require(ImageImport.decode(gray))
    let grayBytes = [UInt8](grayRaster.rgb8)
    #expect(grayBytes[0] == grayBytes[1] && grayBytes[1] == grayBytes[2])
    #expect(grayBytes[0] > 40 && grayBytes[0] < 90)

    // Fully transparent pixels composite over white.
    let alpha = try pngData(width: 2, height: 2) { context in
      context.clear(CGRect(x: 0, y: 0, width: 2, height: 2))
    }
    let alphaRaster = try #require(ImageImport.decode(alpha))
    let alphaBytes = [UInt8](alphaRaster.rgb8)
    #expect(alphaBytes[0] > 250 && alphaBytes[1] > 250 && alphaBytes[2] > 250)
  }

  @Test func rejectsInvalidData() {
    #expect(ImageImport.decode(Data("not an image".utf8)) == nil)
    #expect(ImageImport.decode(Data()) == nil)
  }

  private func pngData(
    width: Int, height: Int, colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue,
    draw: (CGContext) -> Void
  ) throws -> Data {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo))
    draw(context)
    let image = try #require(context.makeImage())
    return try encode(image, type: "public.png", properties: nil)
  }

  private func jpegData(
    width: Int, height: Int, orientation: Int, draw: (CGContext) -> Void
  ) throws -> Data {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    draw(context)
    let image = try #require(context.makeImage())
    return try encode(
      image, type: "public.jpeg",
      properties: [kCGImagePropertyOrientation: orientation] as CFDictionary)
  }

  private func encode(_ image: CGImage, type: String, properties: CFDictionary?) throws -> Data {
    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, properties)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }
}
