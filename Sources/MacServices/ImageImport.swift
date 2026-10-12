import CoreGraphics
import Foundation
import ImageIO
import PDFCore

/// P20-009/P20-010/P20-011: raster import through public ImageIO APIs. EXIF
/// orientation is normalized with the thumbnail transform, and pixels are
/// explicitly converted to 8-bit DeviceRGB with transparency composited over
/// white. Nothing else from the source metadata is carried over.
public enum ImageImport {
  public struct Raster: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let rgb8: Data
  }

  public static let maximumPixels = 40_000_000

  public static func decode(_ data: Data) -> Raster? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 10_000,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }
    let width = image.width
    let height = image.height
    guard width > 0, height > 0, width * height <= maximumPixels else { return nil }

    var rgba = Data(count: width * height * 4)
    let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
      guard let base = buffer.baseAddress,
        let context = CGContext(
          data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return nil }

    var rgb = Data(capacity: width * height * 3)
    rgba.withUnsafeBytes { buffer in
      let base = buffer.bindMemory(to: UInt8.self)
      for index in stride(from: 0, to: width * height * 4, by: 4) {
        rgb.append(base[index])
        rgb.append(base[index + 1])
        rgb.append(base[index + 2])
      }
    }
    return Raster(width: width, height: height, rgb8: rgb)
  }
}
