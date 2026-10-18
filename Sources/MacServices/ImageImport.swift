import CoreGraphics
import Foundation
import ImageIO
import PDFCore

/// P20-009/P20-010/P20-011: raster import through public ImageIO APIs. EXIF
/// orientation is normalized with the thumbnail transform, and pixels are
/// explicitly converted to 8-bit DeviceRGB plus an optional grayscale alpha
/// plane. Nothing else from the source metadata is carried over.
public enum ImageImport {
  public struct Raster: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let rgb8: Data
    public let alpha8: Data?

    public init(width: Int, height: Int, rgb8: Data, alpha8: Data? = nil) {
      self.width = width
      self.height = height
      self.rgb8 = rgb8
      self.alpha8 = alpha8
    }
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
      context.clear(CGRect(x: 0, y: 0, width: width, height: height))
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return nil }

    var rgb = Data(capacity: width * height * 3)
    var alpha = Data(capacity: width * height)
    var hasTransparency = false
    rgba.withUnsafeBytes { buffer in
      let base = buffer.bindMemory(to: UInt8.self)
      for index in stride(from: 0, to: width * height * 4, by: 4) {
        let a = base[index + 3]
        alpha.append(a)
        if a < 255 { hasTransparency = true }
        if a == 0 {
          rgb.append(0); rgb.append(0); rgb.append(0)
        } else if a == 255 {
          rgb.append(base[index]); rgb.append(base[index + 1]); rgb.append(base[index + 2])
        } else {
          // The Core Graphics bitmap is premultiplied. PDF image samples are
          // straight RGB with opacity carried separately by the soft mask.
          rgb.append(UInt8(clamping: (Int(base[index]) * 255 + Int(a) / 2) / Int(a)))
          rgb.append(UInt8(clamping: (Int(base[index + 1]) * 255 + Int(a) / 2) / Int(a)))
          rgb.append(UInt8(clamping: (Int(base[index + 2]) * 255 + Int(a) / 2) / Int(a)))
        }
      }
    }
    return Raster(
      width: width, height: height, rgb8: rgb,
      alpha8: hasTransparency ? alpha : nil)
  }
}
