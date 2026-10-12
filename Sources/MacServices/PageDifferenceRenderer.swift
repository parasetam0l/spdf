import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// P32-006/P32-007: rendered-page difference images with an explicit
/// per-channel tolerance. Differences beyond the tolerance are painted red on
/// a white background; the ratio and maximum channel difference are reported
/// so tolerance settings cannot silently hide known changes (P32-027).
public enum PageDifferenceRenderer {
  public struct Result: @unchecked Sendable {
    public let image: CGImage
    public let changedPixelRatio: Double
    public let maximumDifference: Int
    public let tolerance: Int
  }

  /// Compare one page of two documents at the same rendered size.
  public static func difference(
    left: Data, right: Data, pageIndex: Int, size: NSSize, tolerance: Int = 2
  ) -> Result? {
    guard let leftBitmap = bitmap(data: left, pageIndex: pageIndex, size: size),
      let rightBitmap = bitmap(data: right, pageIndex: pageIndex, size: size),
      let leftPixels = leftBitmap.bitmapData, let rightPixels = rightBitmap.bitmapData
    else { return nil }
    let width = leftBitmap.pixelsWide
    let height = leftBitmap.pixelsHigh
    guard width == rightBitmap.pixelsWide, height == rightBitmap.pixelsHigh,
      leftBitmap.bytesPerRow == rightBitmap.bytesPerRow
    else { return nil }
    let byteCount = leftBitmap.bytesPerRow * height
    let leftBuffer = Array(UnsafeBufferPointer(start: leftPixels, count: byteCount))
    let rightBuffer = Array(UnsafeBufferPointer(start: rightPixels, count: byteCount))
    return difference(
      leftPixels: leftBuffer, rightPixels: rightBuffer, width: width, height: height,
      bytesPerRow: leftBitmap.bytesPerRow, samplesPerPixel: leftBitmap.samplesPerPixel,
      tolerance: tolerance)
  }

  /// Buffer-level comparison, also used by tests with synthetic pixels.
  static func difference(
    leftPixels: [UInt8], rightPixels: [UInt8], width: Int, height: Int, bytesPerRow: Int,
    samplesPerPixel: Int, tolerance: Int
  ) -> Result? {
    guard leftPixels.count == rightPixels.count, samplesPerPixel >= 3, width > 0, height > 0
    else { return nil }
    var output = [UInt8](repeating: 0xFF, count: bytesPerRow * height)
    var changed = 0
    var maximum = 0
    for y in 0..<height {
      for x in 0..<width {
        let index = y * bytesPerRow + x * samplesPerPixel
        let redDifference = abs(Int(leftPixels[index]) - Int(rightPixels[index]))
        let greenDifference = abs(Int(leftPixels[index + 1]) - Int(rightPixels[index + 1]))
        let blueDifference = abs(Int(leftPixels[index + 2]) - Int(rightPixels[index + 2]))
        let difference = max(redDifference, max(greenDifference, blueDifference))
        maximum = max(maximum, difference)
        if difference > tolerance {
          changed += 1
          output[index] = 0xFF
          output[index + 1] = 0x00
          output[index + 2] = 0x00
          if samplesPerPixel > 3 { output[index + 3] = 0xFF }
        }
      }
    }
    guard
      let provider = CGDataProvider(data: Data(output) as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: samplesPerPixel * 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { return nil }
    return Result(
      image: image, changedPixelRatio: Double(changed) / Double(width * height),
      maximumDifference: maximum, tolerance: tolerance)
  }

  static func bitmap(data: Data, pageIndex: Int, size: NSSize) -> NSBitmapImageRep? {
    guard let document = PDFDocument(data: data), let page = document.page(at: pageIndex)
    else { return nil }
    let image = page.thumbnail(of: size, for: .cropBox)
    guard
      let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    image.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    return representation
  }
}
