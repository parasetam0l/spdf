import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFCore
import PDFEditing
import PDFKit
import UniformTypeIdentifiers

/// OCR-04/OCR-05: decoded 8-bit RGB pixels for one page scan image. The
/// raster is always plain DeviceRGB so pixel edits cannot accidentally depend
/// on the source codec; the source stream stays in the graph as the recoverable
/// original.
public struct ScanRaster: Sendable, Equatable {
  public let width: Int
  public let height: Int
  public var rgb8: Data

  public init(width: Int, height: Int, rgb8: Data) throws {
    guard width > 0, height > 0, width <= 20_000, height <= 20_000 else {
      throw PDFError(.limitExceeded, "The scan image is too large to clean up")
    }
    guard rgb8.count == width * height * 3 else {
      throw PDFError(.malformed, "The scan raster does not match its dimensions")
    }
    self.width = width
    self.height = height
    self.rgb8 = rgb8
  }

  public var pixelCount: Int { width * height }

  public func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
    let offset = (y * width + x) * 3
    return (rgb8[offset], rgb8[offset + 1], rgb8[offset + 2])
  }

  public mutating func setPixel(x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8) {
    let offset = (y * width + x) * 3
    rgb8[offset] = r
    rgb8[offset + 1] = g
    rgb8[offset + 2] = b
  }

  public func luminance(x: Int, y: Int) -> Double {
    let (r, g, b) = pixel(x: x, y: y)
    return 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
  }

  /// Bounded grayscale copy used by detectors; keeps detail enough for skew
  /// and ink statistics while capping work on large scans.
  public func grayscale(maxDimension: Int = 1_200) -> (width: Int, height: Int, values: [Double]) {
    let scale = min(1, Double(maxDimension) / Double(max(width, height)))
    let outWidth = max(1, Int((Double(width) * scale).rounded()))
    let outHeight = max(1, Int((Double(height) * scale).rounded()))
    var values = [Double](repeating: 255, count: outWidth * outHeight)
    for y in 0..<outHeight {
      let sourceY = min(height - 1, Int(Double(y) / scale))
      for x in 0..<outWidth {
        let sourceX = min(width - 1, Int(Double(x) / scale))
        values[y * outWidth + x] = luminance(x: sourceX, y: sourceY)
      }
    }
    return (outWidth, outHeight, values)
  }

  /// Crops to the given rectangle after clamping; out-of-range crops refuse
  /// instead of silently producing an empty image.
  public func cropped(x: Int, y: Int, width cropWidth: Int, height cropHeight: Int) throws
    -> ScanRaster
  {
    guard x >= 0, y >= 0, cropWidth > 0, cropHeight > 0,
      x + cropWidth <= width, y + cropHeight <= height
    else {
      throw PDFError(.malformed, "The scan crop rectangle falls outside the image")
    }
    var output = Data(capacity: cropWidth * cropHeight * 3)
    for row in y..<(y + cropHeight) {
      let start = (row * width + x) * 3
      output.append(rgb8[start..<(start + cropWidth * 3)])
    }
    return try ScanRaster(width: cropWidth, height: cropHeight, rgb8: output)
  }
}

/// OCR-04: image decoding for cleanup. Selection-based extraction already
/// preserves original bytes for recovery; this decoder only supports the
/// codecs the cleanup profile can honestly process.
public enum ScanImageRaster {
  /// Decode the image stream behind one placement.
  public static func raster(imageID: PDFObjectID, in graph: PDFGraph) throws -> ScanRaster {
    guard case .stream(let stream)? = graph.objects[imageID] else {
      throw ScanCleanupRefusal.imageUnavailable("The page image object is missing")
    }
    guard stream.dictionary[PDFName("SMask")] == nil,
      stream.dictionary[PDFName("Mask")] == nil,
      stream.dictionary[PDFName("ImageMask")] != .boolean(true)
    else {
      throw ScanCleanupRefusal.unsupportedPaint(
        "The scan uses a mask; cleanup cannot preserve its transparency reliably")
    }
    let width = integer(stream.dictionary[PDFName("Width")])
    let height = integer(stream.dictionary[PDFName("Height")])
    guard let width, let height else {
      throw ScanCleanupRefusal.imageUnavailable("The scan image has no usable dimensions")
    }
    let colorSpace = colorSpaceName(stream.dictionary[PDFName("ColorSpace")])
    let filters = filterNames(stream.dictionary[PDFName("Filter")])
    if filters.contains(where: { $0 == "DCTDecode" || $0 == "JPXDecode" })
      || colorSpace != "DeviceRGB" && colorSpace != "DeviceGray"
      || integer(stream.dictionary[PDFName("BitsPerComponent")]) != 8
    {
      // JPEG/JPX or non-8-bit samples are common for real scans; decode them
      // through ImageIO instead of refusing the whole workflow.
      return try rasterThroughImageIO(stream: stream, width: width, height: height)
    }
    guard let colorSpace else {
      throw ScanCleanupRefusal.imageUnavailable("The scan image has no color space")
    }
    let decoded: Data
    do {
      decoded = try PDFFilters.decoded(stream)
    } catch {
      throw ScanCleanupRefusal.imageUnavailable("The scan image could not be decoded")
    }
    let components = colorSpace == "DeviceGray" ? 1 : 3
    guard decoded.count == width * height * components else {
      throw ScanCleanupRefusal.imageUnavailable("The scan samples do not match their dimensions")
    }
    if components == 3 {
      return try ScanRaster(width: width, height: height, rgb8: decoded)
    }
    var rgb = Data(capacity: width * height * 3)
    for value in decoded {
      rgb.append(value)
      rgb.append(value)
      rgb.append(value)
    }
    return try ScanRaster(width: width, height: height, rgb8: rgb)
  }

  /// Extract one image object's stored bytes as an independent file payload.
  public static func originalBytes(imageID: PDFObjectID, in graph: PDFGraph) throws -> Data {
    guard case .stream(let stream)? = graph.objects[imageID] else {
      throw ScanCleanupRefusal.imageUnavailable("The page image object is missing")
    }
    return stream.bytes
  }

  static func rasterThroughImageIO(
    stream: PDFStream, width: Int, height: Int
  ) throws -> ScanRaster {
    let bytes = stream.bytes
    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw ScanCleanupRefusal.imageUnavailable(
        "The scan codec is not supported by the cleanup profile")
    }
    guard image.width > 0, image.height > 0 else {
      throw ScanCleanupRefusal.imageUnavailable("The scan image has no pixels")
    }
    var pixels = Data(count: image.width * image.height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ok: Bool = pixels.withUnsafeMutableBytes { buffer in
      guard let base = buffer.baseAddress,
        let context = CGContext(
          data: base, width: image.width, height: image.height,
          bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.interpolationQuality = .high
      context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      context.fill(
        CGRect(x: 0, y: 0, width: image.width, height: image.height))
      context.draw(
        image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    guard ok else {
      throw ScanCleanupRefusal.imageUnavailable("The scan image could not be converted to RGB")
    }
    var rgb = Data(capacity: image.width * image.height * 3)
    for offset in stride(from: 0, to: pixels.count, by: 4) {
      rgb.append(pixels[offset])
      rgb.append(pixels[offset + 1])
      rgb.append(pixels[offset + 2])
    }
    return try ScanRaster(width: image.width, height: image.height, rgb8: rgb)
  }

  static func integer(_ value: PDFValue?) -> Int? {
    guard case .integer(let raw)? = value, let int = Int(exactly: raw) else { return nil }
    return int
  }

  static func colorSpaceName(_ value: PDFValue?) -> String? {
    switch value {
    case .name(let name): return String(decoding: name.bytes, as: UTF8.self)
    case .array(let members):
      if case .name(let name)? = members.first {
        return String(decoding: name.bytes, as: UTF8.self)
      }
      return nil
    default:
      return nil
    }
  }

  static func filterNames(_ value: PDFValue?) -> [String] {
    switch value {
    case .name(let name): return [String(decoding: name.bytes, as: UTF8.self)]
    case .array(let members):
      return members.compactMap { member in
        if case .name(let name) = member { return String(decoding: name.bytes, as: UTF8.self) }
        return nil
      }
    default:
      return []
    }
  }
}

/// OCR-04: deterministic pixel analysis shared by preview, apply and tests.
public enum ScanInkAnalysis {
  public static func inkPixelCount(
    _ raster: ScanRaster, threshold: Double = 160, region: CGRect? = nil
  ) -> Int {
    let bounds = clampedRegion(region, width: raster.width, height: raster.height)
    var count = 0
    for y in bounds.minY..<bounds.maxY {
      for x in bounds.minX..<bounds.maxX where raster.luminance(x: x, y: y) < threshold {
        count += 1
      }
    }
    return count
  }

  public static func inkBounds(
    _ raster: ScanRaster, threshold: Double = 160
  ) -> CGRect? {
    var minX = raster.width, minY = raster.height, maxX = -1, maxY = -1
    for y in 0..<raster.height {
      for x in 0..<raster.width where raster.luminance(x: x, y: y) < threshold {
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
      }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
  }

  /// Mean/std-dev of a border ring around the region; a flat ring means the
  /// background behind a scan word can be erased without visible patches.
  public static func backgroundStats(
    _ raster: ScanRaster, region: CGRect, ringWidth: Int = 4
  ) -> (mean: (Double, Double, Double), spread: Double) {
    let bounds = clampedRegion(region, width: raster.width, height: raster.height)
    var values: [(Double, Double, Double)] = []
    let ring = max(1, ringWidth)
    var x = max(0, bounds.minX - ring)
    while x < min(raster.width, bounds.maxX + ring) {
      var y = max(0, bounds.minY - ring)
      while y < min(raster.height, bounds.maxY + ring) {
        let inside = x >= bounds.minX && x < bounds.maxX && y >= bounds.minY
          && y < bounds.maxY
        if !inside {
          let (r, g, b) = raster.pixel(x: x, y: y)
          values.append((Double(r), Double(g), Double(b)))
        }
        y += 1
      }
      x += 1
    }
    guard !values.isEmpty else { return ((255, 255, 255), 0) }
    let count = Double(values.count)
    let mean = (
      values.reduce(0) { $0 + $1.0 } / count,
      values.reduce(0) { $0 + $1.1 } / count,
      values.reduce(0) { $0 + $1.2 } / count)
    let spread = values.reduce(0.0) { partial, value in
      let dr = value.0 - mean.0, dg = value.1 - mean.1, db = value.2 - mean.2
      return partial + sqrt((dr * dr + dg * dg + db * db) / 3)
    } / count
    return (mean, spread)
  }

  public static func clampedRegion(
    _ region: CGRect?, width: Int, height: Int
  ) -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
    guard let region else { return (0, width, 0, height) }
    let minX = max(0, min(width, Int(region.minX.rounded(.down))))
    let maxX = max(minX, min(width, Int(region.maxX.rounded(.up))))
    let minY = max(0, min(height, Int(region.minY.rounded(.down))))
    let maxY = max(minY, min(height, Int(region.maxY.rounded(.up))))
    return (minX, maxX, minY, maxY)
  }

  /// OCR-04 deskew detection: choose the rotation that minimizes the height of
  /// the transformed ink bounding box. A block of text lines is widest and
  /// shortest when the lines are horizontal, so the minimum is the correction
  /// angle; the search is bounded to small scanner skew.
  public static func estimateSkewDegrees(
    _ raster: ScanRaster, searchDegrees: Double = 8, step: Double = 0.25
  ) -> Double {
    let gray = raster.grayscale(maxDimension: 500)
    var bestAngle = 0.0
    var bestHeight = Double.infinity
    let angleCount = Int((searchDegrees * 2 / step).rounded()) + 1
    for index in 0..<angleCount {
      let angle = -searchDegrees + Double(index) * step
      let height = transformedInkHeight(
        width: gray.width, height: gray.height, values: gray.values, angle: angle)
      if height < bestHeight - 1e-9
        || (abs(height - bestHeight) <= 1e-9 && abs(angle) < abs(bestAngle))
      {
        bestHeight = height
        bestAngle = angle
      }
    }
    return bestAngle
  }

  static func transformedInkHeight(
    width: Int, height: Int, values: [Double], angle: Double
  ) -> Double {
    guard width > 0, height > 0 else { return 0 }
    let radians = angle * .pi / 180
    let cosValue = cos(radians)
    let sinValue = sin(radians)
    let centerX = Double(width) / 2
    let centerY = Double(height) / 2
    var minimum = Double.infinity
    var maximum = -Double.infinity
    for y in 0..<height {
      for x in 0..<width where values[y * width + x] < 160 {
        let dx = Double(x) - centerX
        let dy = Double(y) - centerY
        let rotatedY = dy * cosValue - dx * sinValue
        minimum = min(minimum, rotatedY)
        maximum = max(maximum, rotatedY)
      }
    }
    guard maximum >= minimum else { return 0 }
    return maximum - minimum
  }

  static func projectionVariance(
    width: Int, height: Int, values: [Double], angle: Double
  ) -> Double {
    guard width > 0, height > 0 else { return 0 }
    let radians = angle * .pi / 180
    let cosValue = cos(radians)
    let sinValue = sin(radians)
    let centerX = Double(width) / 2
    let centerY = Double(height) / 2
    var rows = [Double](repeating: 0, count: height)
    for y in 0..<height {
      for x in 0..<width where values[y * width + x] < 160 {
        let dx = Double(x) - centerX
        let dy = Double(y) - centerY
        let rotatedY = dy * cosValue - dx * sinValue + centerY
        let row = Int(rotatedY.rounded())
        if row >= 0 && row < height { rows[row] += 1 }
      }
    }
    let total = rows.reduce(0, +)
    guard total > 0 else { return 0 }
    let mean = total / Double(height)
    return rows.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(height)
  }
}

/// OCR-04: raster transforms. Every transform returns a new raster; the source
/// stays untouched so preview and apply share the same deterministic bytes.
public enum ScanImageTransform {
  public static func rotateQuarterTurns(_ raster: ScanRaster, turns: Int) throws -> ScanRaster {
    let normalized = ((turns % 4) + 4) % 4
    guard normalized != 0 else { return raster }
    let swaps = normalized % 2 == 1
    let outWidth = swaps ? raster.height : raster.width
    let outHeight = swaps ? raster.width : raster.height
    var output = Data(count: outWidth * outHeight * 3)
    for y in 0..<raster.height {
      for x in 0..<raster.width {
        let (r, g, b) = raster.pixel(x: x, y: y)
        let target: (Int, Int)
        switch normalized {
        case 1: target = (raster.height - 1 - y, x)
        case 2: target = (raster.width - 1 - x, raster.height - 1 - y)
        default: target = (y, raster.width - 1 - x)
        }
        let offset = (target.1 * outWidth + target.0) * 3
        output[offset] = r
        output[offset + 1] = g
        output[offset + 2] = b
      }
    }
    return try ScanRaster(width: outWidth, height: outHeight, rgb8: output)
  }

  /// Rotate by the given degrees around the center; the canvas keeps every
  /// corner of the rotated image (white outside).
  public static func deskewed(_ raster: ScanRaster, degrees: Double) throws -> ScanRaster {
    guard abs(degrees) > 0.001 else { return raster }
    return try redrawn(raster) { context in
      context.translateBy(x: CGFloat(raster.width) / 2, y: CGFloat(raster.height) / 2)
      context.rotate(by: CGFloat(degrees * .pi / 180))
      context.translateBy(x: -CGFloat(raster.width) / 2, y: -CGFloat(raster.height) / 2)
    }
  }

  public static func autoContrast(_ raster: ScanRaster) throws -> ScanRaster {
    var histogram = [Int](repeating: 0, count: 256)
    for value in raster.rgb8 { histogram[Int(value)] += 1 }
    let total = raster.rgb8.count
    guard total > 0 else { return raster }
    let lowTarget = Int(Double(total) * 0.005)
    let highTarget = Int(Double(total) * 0.995)
    var low = 0, high = 255, accumulated = 0
    for value in 0..<256 {
      accumulated += histogram[value]
      if accumulated >= lowTarget { low = value; break }
    }
    accumulated = 0
    for value in stride(from: 255, through: 0, by: -1) {
      accumulated += histogram[value]
      if accumulated >= total - highTarget { high = value; break }
    }
    guard high > low else { return raster }
    var lookup = [UInt8](repeating: 0, count: 256)
    for value in 0..<256 {
      let scaled = (Double(value - low) / Double(high - low)) * 255
      lookup[value] = UInt8(max(0, min(255, scaled.rounded())))
    }
    var output = Data(capacity: raster.rgb8.count)
    for value in raster.rgb8 { output.append(lookup[Int(value)]) }
    return try ScanRaster(width: raster.width, height: raster.height, rgb8: output)
  }

  /// Flatten light scanner background to pure white while keeping mid-tone and
  /// dark ink samples; the report records how much of the page became paper.
  public static func flattenedBackground(
    _ raster: ScanRaster, whitePoint: Double = 205
  ) throws -> ScanRaster {
    var output = raster.rgb8
    for offset in stride(from: 0, to: output.count, by: 3) {
      let r = Double(output[offset]), g = Double(output[offset + 1])
      let b = Double(output[offset + 2])
      let luminance = 0.299 * r + 0.587 * g + 0.114 * b
      if luminance >= whitePoint,
        abs(r - g) < 20, abs(g - b) < 20
      {
        output[offset] = 255
        output[offset + 1] = 255
        output[offset + 2] = 255
      }
    }
    return try ScanRaster(width: raster.width, height: raster.height, rgb8: output)
  }

  public static func cropped(_ raster: ScanRaster, to rect: CGRect) throws -> ScanRaster {
    let bounds = ScanInkAnalysis.clampedRegion(rect, width: raster.width, height: raster.height)
    let width = bounds.maxX - bounds.minX
    let height = bounds.maxY - bounds.minY
    guard width > 16, height > 16 else {
      throw ScanCleanupRefusal.cropWouldRemoveContent(
        "The crop would leave almost no scanned content")
    }
    return try raster.cropped(x: bounds.minX, y: bounds.minY, width: width, height: height)
  }

  /// Letterbox a processed raster into a canvas of the page placement's aspect
  /// ratio. Keeping the aspect identical means the existing image draw matrix
  /// stays valid and the saved page shows exactly the previewed bytes.
  public static func fittedToAspect(
    _ raster: ScanRaster, aspect: Double
  ) throws -> ScanRaster {
    guard aspect.isFinite, aspect > 0.01, aspect < 100 else {
      throw ScanCleanupRefusal.imageUnavailable("The scan placement has no usable aspect ratio")
    }
    let contentAspect = Double(raster.width) / Double(raster.height)
    var canvasWidth: Int
    var canvasHeight: Int
    if contentAspect > aspect {
      canvasWidth = raster.width
      canvasHeight = max(1, Int((Double(canvasWidth) / aspect).rounded()))
    } else {
      canvasHeight = raster.height
      canvasWidth = max(1, Int((Double(canvasHeight) * aspect).rounded()))
    }
    let scale = min(
      Double(canvasWidth) / Double(raster.width),
      Double(canvasHeight) / Double(raster.height))
    let drawWidth = max(1, Int((Double(raster.width) * scale).rounded()))
    let drawHeight = max(1, Int((Double(raster.height) * scale).rounded()))
    let originX = (canvasWidth - drawWidth) / 2
    let originY = (canvasHeight - drawHeight) / 2
    var output = Data(repeating: 255, count: canvasWidth * canvasHeight * 3)
    for y in 0..<drawHeight {
      let sourceY = min(raster.height - 1, Int(Double(y) / scale))
      for x in 0..<drawWidth {
        let sourceX = min(raster.width - 1, Int(Double(x) / scale))
        let (r, g, b) = raster.pixel(x: sourceX, y: sourceY)
        let offset = ((originY + y) * canvasWidth + originX + x) * 3
        output[offset] = r
        output[offset + 1] = g
        output[offset + 2] = b
      }
    }
    return try ScanRaster(width: canvasWidth, height: canvasHeight, rgb8: output)
  }

  public static func grayscaleLuminanceData(_ raster: ScanRaster) -> [Double] {
    raster.grayscale().values
  }

  static func redrawn(
    _ raster: ScanRaster, transform: (CGContext) -> Void
  ) throws -> ScanRaster {
    guard let image = raster.cgImage() else {
      throw ScanCleanupRefusal.imageUnavailable("The scan raster could not be redrawn")
    }
    var pixels = Data(count: raster.width * raster.height * 4)
    let ok: Bool = pixels.withUnsafeMutableBytes { buffer in
      guard let base = buffer.baseAddress,
        let context = CGContext(
          data: base, width: raster.width, height: raster.height,
          bitsPerComponent: 8, bytesPerRow: raster.width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
      context.interpolationQuality = .high
      transform(context)
      context.draw(image, in: CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
      return true
    }
    guard ok else {
      throw ScanCleanupRefusal.imageUnavailable("The scan raster could not be transformed")
    }
    var output = Data(capacity: raster.width * raster.height * 3)
    for offset in stride(from: 0, to: pixels.count, by: 4) {
      output.append(pixels[offset])
      output.append(pixels[offset + 1])
      output.append(pixels[offset + 2])
    }
    return try ScanRaster(width: raster.width, height: raster.height, rgb8: output)
  }
}

extension ScanRaster {
  public func cgImage() -> CGImage? {
    var pixels = Data(count: width * height * 4)
    for index in 0..<pixelCount {
      let source = index * 3
      let target = index * 4
      pixels[target] = rgb8[source]
      pixels[target + 1] = rgb8[source + 1]
      pixels[target + 2] = rgb8[source + 2]
      pixels[target + 3] = 255
    }
    guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  public func pngData() throws -> Data {
    guard let image = cgImage() else {
      throw ScanCleanupRefusal.imageUnavailable("The scan raster could not be encoded")
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data, UTType.png.identifier as CFString, 1, nil)
    else {
      throw ScanCleanupRefusal.imageUnavailable("The scan preview could not be encoded")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw ScanCleanupRefusal.imageUnavailable("The scan preview could not be encoded")
    }
    return data as Data
  }
}

/// OCR-04/OCR-05: render the current graph to pixels without mutating it. The
/// preview is always produced from the same bytes the apply step commits.
public enum ScanPageRenderer {
  public static func cgImage(
    graph: PDFGraph, pageIndex: Int, pixelWidth: Int = 900
  ) throws -> CGImage {
    let data = try PDFWriter.write(graph)
    guard let document = PDFDocument(data: data), pageIndex >= 0,
      pageIndex < document.pageCount, let page = document.page(at: pageIndex)
    else {
      throw ScanCleanupRefusal.pageUnavailable("The page could not be rendered")
    }
    return try render(page: page, pixelWidth: pixelWidth)
  }

  public static func pngData(
    graph: PDFGraph, pageIndex: Int, pixelWidth: Int = 900
  ) throws -> Data {
    let image = try cgImage(graph: graph, pageIndex: pageIndex, pixelWidth: pixelWidth)
    return try pngData(image: image)
  }

  /// Render a single page of a standalone PDF data payload.
  public static func pageCGImage(
    data: Data, pageIndex: Int, pixelWidth: Int = 900
  ) throws -> CGImage {
    guard let document = PDFDocument(data: data), pageIndex >= 0,
      pageIndex < document.pageCount, let page = document.page(at: pageIndex)
    else {
      throw ScanCleanupRefusal.pageUnavailable("The page could not be rendered")
    }
    return try render(page: page, pixelWidth: pixelWidth)
  }

  public static func pngData(image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data, UTType.png.identifier as CFString, 1, nil)
    else {
      throw ScanCleanupRefusal.pageUnavailable("The page preview could not be encoded")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw ScanCleanupRefusal.pageUnavailable("The page preview could not be encoded")
    }
    return data as Data
  }

  static func render(page: PDFPage, pixelWidth: Int) throws -> CGImage {
    let bounds = page.bounds(for: .mediaBox)
    guard bounds.width > 0, bounds.height > 0 else {
      throw ScanCleanupRefusal.pageUnavailable("The page has no visible bounds")
    }
    let scale = Double(pixelWidth) / bounds.width
    let width = max(1, Int((bounds.width * scale).rounded()))
    let height = max(1, Int((bounds.height * scale).rounded()))
    guard width <= 20_000, height <= 20_000 else {
      throw ScanCleanupRefusal.pageUnavailable("The page preview is too large")
    }
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
      throw ScanCleanupRefusal.pageUnavailable("The page preview could not be rendered")
    }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: context)
    guard let image = context.makeImage() else {
      throw ScanCleanupRefusal.pageUnavailable("The page preview could not be rendered")
    }
    return image
  }
}
