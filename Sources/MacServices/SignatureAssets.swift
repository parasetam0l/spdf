import CoreGraphics
import Foundation
import ImageIO
import PDFCore
import PDFEditing
import UniformTypeIdentifiers

/// P29-001/P29-002/P29-005/P29-006: turn captured strokes into a signature
/// asset. Strokes are in view coordinates (y down); rendering smooths the
/// polyline with a quadratic midpoint scheme, keeps transparency, and is
/// deterministic for the same input.
public enum SignatureCapture {
  public struct Stroke: Sendable, Equatable {
    /// Points in view coordinates `[x, y]`, y down.
    public let points: [[Double]]
    /// Stroke width in points.
    public let width: Double

    public init(points: [[Double]], width: Double = 3) {
      self.points = points
      self.width = width
    }
  }

  /// Render strokes on a transparent background.
  public static func render(
    strokes: [Stroke], size: CGSize, color: [Double] = [0, 0, 0]
  ) -> SignatureAsset {
    let width = max(1, Int(size.width.rounded()))
    let height = max(1, Int(size.height.rounded()))
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
      return SignatureAsset(
        id: "empty", kind: .drawn, width: 1, height: 1, rgb8: Data([0, 0, 0]))
    }
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.setStrokeColor(
      CGColor(red: color[0], green: color[1], blue: color[2], alpha: 1))
    context.setLineCap(.round)
    context.setLineJoin(.round)
    for stroke in strokes where !stroke.points.isEmpty {
      context.setLineWidth(max(0.5, stroke.width))
      let smoothed = smooth(stroke.points)
      context.beginPath()
      // Flip y so view coordinates (y down) map to bitmap coordinates.
      context.move(
        to: CGPoint(x: smoothed[0][0], y: Double(height) - smoothed[0][1]))
      for point in smoothed.dropFirst() {
        context.addLine(to: CGPoint(x: point[0], y: Double(height) - point[1]))
      }
      context.strokePath()
    }
    guard let image = context.makeImage() else {
      return SignatureAsset(
        id: "empty", kind: .drawn, width: 1, height: 1, rgb8: Data([0, 0, 0]))
    }
    var asset = assetFrom(image: image, kind: .drawn)
    asset = asset.cropped()
    return asset
  }

  /// Quadratic midpoint smoothing that preserves the intended strokes.
  static func smooth(_ points: [[Double]]) -> [[Double]] {
    guard points.count > 2 else { return points }
    var result: [[Double]] = [points[0]]
    for index in 1..<(points.count - 1) {
      let previous = points[index - 1]
      let current = points[index]
      let next = points[index + 1]
      let mid = [(current[0] + next[0]) / 2, (current[1] + next[1]) / 2]
      let control = [
        current[0] + (previous[0] - current[0]) * 0.15,
        current[1] + (previous[1] - current[1]) * 0.15,
      ]
      result.append([
        (control[0] + mid[0]) / 2, (control[1] + mid[1]) / 2,
      ])
    }
    result.append(points[points.count - 1])
    return result
  }

  /// P29-003: import an image through ImageIO, preserving alpha when present.
  public static func importAsset(from data: Data, kind: SignatureAsset.Kind = .imported) throws
    -> SignatureAsset
  {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw PageImageExport.ExportError.encodingFailed
    }
    return assetFrom(image: image, kind: kind)
  }

  static func assetFrom(image: CGImage, kind: SignatureAsset.Kind) -> SignatureAsset {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard
      let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
      return SignatureAsset(id: "empty", kind: kind, width: 1, height: 1, rgb8: Data([0, 0, 0]))
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var rgb = Data(capacity: width * height * 3)
    var alpha = Data(capacity: width * height)
    var hasTransparency = false
    for index in stride(from: 0, to: pixels.count, by: 4) {
      let a = pixels[index + 3]
      if a < 255 { hasTransparency = true }
      // Un-premultiply so the stored RGB is the true color.
      let scale = a == 0 ? 0 : 255.0 / Double(a)
      rgb.append(UInt8(min(255, Double(pixels[index]) * scale)))
      rgb.append(UInt8(min(255, Double(pixels[index + 1]) * scale)))
      rgb.append(UInt8(min(255, Double(pixels[index + 2]) * scale)))
      alpha.append(a)
    }
    let identifier = SignatureAsset.identifier(
      kind: kind, width: width, height: height, rgb8: rgb,
      alpha8: hasTransparency ? alpha : nil)
    return SignatureAsset(
      id: identifier, kind: kind, width: width, height: height, rgb8: rgb,
      alpha8: hasTransparency ? alpha : nil)
  }
}

/// P29-007/P29-008/P29-009/P29-023/P29-024/P29-030: a local, owner-only asset
/// store. Files are PNGs named by asset identity; nothing is logged and
/// nothing leaves the machine.
public struct SignatureAssetStore: Sendable {
  public let directory: URL

  /// Bounds: at most 500 assets and 8 MiB per asset.
  public static let maxAssets = 500
  public static let maxAssetBytes = 8 * 1_024 * 1_024

  public init(directory: URL) {
    self.directory = directory
  }

  public static func defaultDirectory() -> URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("spdf/Signatures", isDirectory: true)
  }

  /// PNG bytes for one asset (RGBA with the asset's alpha).
  public func data(for asset: SignatureAsset) throws -> Data {
    let rgba = Self.rgba(for: asset)
    guard
      let provider = CGDataProvider(data: Data(rgba) as CFData),
      let image = CGImage(
        width: asset.width, height: asset.height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: asset.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else {
      throw PageImageExport.ExportError.encodingFailed
    }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)
    else {
      throw PageImageExport.ExportError.encodingFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw PageImageExport.ExportError.encodingFailed
    }
    return output as Data
  }

  static func rgba(for asset: SignatureAsset) -> [UInt8] {
    var rgba = [UInt8](repeating: 0, count: asset.width * asset.height * 4)
    let alpha = asset.alpha8
    for pixel in 0..<(asset.width * asset.height) {
      rgba[pixel * 4] = asset.rgb8[pixel * 3]
      rgba[pixel * 4 + 1] = asset.rgb8[pixel * 3 + 1]
      rgba[pixel * 4 + 2] = asset.rgb8[pixel * 3 + 2]
      rgba[pixel * 4 + 3] = alpha?[pixel] ?? 255
    }
    return rgba
  }

  /// P29-007: save only when the caller explicitly asks; duplicates collapse
  /// onto the same identity (P29-024).
  @discardableResult
  public func save(_ asset: SignatureAsset) throws -> URL {
    guard asset.isWellFormed else {
      throw PDFError(.malformed, "The signature asset is empty or malformed")
    }
    let encoded = try data(for: asset)
    guard encoded.count <= Self.maxAssetBytes else {
      throw PDFError(.limitExceeded, "The signature asset exceeds the size limit")
    }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let existing = try list()
    guard existing.contains(where: { $0.id == asset.id }) || existing.count < Self.maxAssets
    else {
      throw PDFError(.limitExceeded, "The signature asset store is full")
    }
    let url = directory.appendingPathComponent("\(asset.id).png")
    try encoded.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
  }

  /// P29-008/P29-023: list and delete stored assets. Deleting an asset never
  /// touches documents that already embedded its pixels.
  public func list() throws -> [SignatureAsset] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    var assets: [SignatureAsset] = []
    for file in files where file.pathExtension.lowercased() == "png" {
      guard let data = try? Data(contentsOf: file), data.count <= Self.maxAssetBytes,
        let decoded = try? Self.decode(data)
      else { continue }
      // The stored filename carries the asset identity; PNG round-trips can
      // shift pixels by a rounding step, so the identity is not recomputed.
      assets.append(
        SignatureAsset(
          id: file.deletingPathExtension().lastPathComponent, kind: decoded.kind,
          width: decoded.width, height: decoded.height, rgb8: decoded.rgb8,
          alpha8: decoded.alpha8, createdAt: decoded.createdAt))
    }
    return assets.sorted { $0.id < $1.id }
  }

  public func delete(id: String) throws {
    let url = directory.appendingPathComponent("\(id).png")
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  /// Decode a stored PNG back into an asset (alpha preserved when present).
  public static func decode(_ data: Data) throws -> SignatureAsset {
    try SignatureCapture.importAsset(from: data, kind: .drawn)
  }
}
