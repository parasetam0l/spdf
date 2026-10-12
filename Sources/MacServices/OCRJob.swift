import CoreGraphics
import Foundation
import PDFCore
import PDFKit
import Vision

/// P26-007: one recognition observation with its confidence and Vision
/// normalized box (origin at the bottom-left of the rendered image).
public struct OCRObservation: Sendable, Equatable {
  public let text: String
  public let confidence: Double
  public let boundingBox: CGRect

  public init(text: String, confidence: Double, boundingBox: CGRect) {
    self.text = text
    self.confidence = confidence
    self.boundingBox = boundingBox
  }
}

public enum OCRRecognitionLevel: String, Sendable {
  case fast
  case accurate
}

/// P26-003: the recognition seam, so jobs are testable without Vision and
/// callers can substitute another local recognizer.
public protocol TextRecognizing: Sendable {
  func recognize(image: CGImage, languages: [String], level: OCRRecognitionLevel) throws
    -> [OCRObservation]
}

/// P26-001/P26-002: the Vision-backed recognizer. Recognition is local; no
/// text leaves the machine, and results are never logged.
public struct VisionTextRecognizer: TextRecognizing {
  public init() {}

  /// P26-002: the languages this system can actually recognize.
  public static func supportedLanguages() throws -> [String] {
    let request = VNRecognizeTextRequest()
    do {
      return try request.supportedRecognitionLanguages()
    } catch {
      throw PDFError(
        .unsupported,
        "Vision text recognition is unavailable on this system: \(error.localizedDescription)")
    }
  }

  public func recognize(
    image: CGImage, languages: [String], level: OCRRecognitionLevel
  ) throws -> [OCRObservation] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = level == .accurate ? .accurate : .fast
    request.usesLanguageCorrection = false
    if !languages.isEmpty { request.recognitionLanguages = languages }
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
      try handler.perform([request])
    } catch {
      throw PDFError(
        .unsupported,
        "Vision text recognition failed on this system: \(error.localizedDescription)")
    }
    return (request.results ?? []).compactMap { observation in
      guard let candidate = observation.topCandidates(1).first else { return nil }
      return OCRObservation(
        text: candidate.string, confidence: Double(candidate.confidence),
        boundingBox: observation.boundingBox)
    }
  }
}

/// P26-005: maps a Vision-normalized box on the rendered image back to
/// unrotated page space, honoring the crop box origin and page rotation.
public struct OCRPageTransform: Sendable, Equatable {
  public let imageWidth: Double
  public let imageHeight: Double
  public let cropBox: [Double]
  /// Normalized to 0, 90, 180, or 270.
  public let rotation: Int

  public init(imageWidth: Double, imageHeight: Double, cropBox: [Double], rotation: Int) {
    self.imageWidth = imageWidth
    self.imageHeight = imageHeight
    self.cropBox = cropBox
    self.rotation = ((rotation % 360) + 360) % 360
  }

  /// Page-space rectangle for one normalized box.
  public func pageRect(forNormalizedBox box: CGRect) -> [Double] {
    guard imageWidth > 0, imageHeight > 0, cropBox.count == 4 else { return [0, 0, 0, 0] }
    let cropWidth = cropBox[2] - cropBox[0]
    let cropHeight = cropBox[3] - cropBox[1]
    let displayWidth = rotation % 180 == 0 ? cropWidth : cropHeight
    let displayHeight = rotation % 180 == 0 ? cropHeight : cropWidth
    // Normalized (bottom-left origin) → display-space points.
    let x0 = Double(box.minX) * displayWidth
    let x1 = Double(box.maxX) * displayWidth
    let y0 = Double(box.minY) * displayHeight
    let y1 = Double(box.maxY) * displayHeight
    // Display space → crop-relative page space. PDFKit draws /Rotate 90 as
    // `display = (y_page, cropWidth − x_page)` (verified against rendered
    // pixels); 180 and 270 compose from that.
    func unrotate(_ x: Double, _ y: Double) -> (Double, Double) {
      switch rotation {
      case 90: return (cropWidth - y, x)
      case 180: return (cropWidth - x, cropHeight - y)
      case 270: return (y, cropHeight - x)
      default: return (x, y)
      }
    }
    let corners = [
      unrotate(x0, y0), unrotate(x0, y1), unrotate(x1, y0), unrotate(x1, y1),
    ]
    let xs = corners.map { $0.0 + cropBox[0] }
    let ys = corners.map { $0.1 + cropBox[1] }
    return [xs.min()!, ys.min()!, xs.max()!, ys.max()!]
  }

  /// P27-003: the inverse direction, for regions drawn in displayed page
  /// space (rotation and crop box applied, as PDFKit reports selection
  /// bounds) that must become unrotated page coordinates for redaction.
  public func pageRect(forDisplayRect rect: [Double]) -> [Double] {
    guard rect.count == 4, cropBox.count == 4 else { return [0, 0, 0, 0] }
    let cropWidth = cropBox[2] - cropBox[0]
    let cropHeight = cropBox[3] - cropBox[1]
    func toPage(_ x: Double, _ y: Double) -> (Double, Double) {
      switch rotation {
      case 90: return (cropWidth - y + cropBox[0], x + cropBox[1])
      case 180: return (cropWidth - x + cropBox[0], cropHeight - y + cropBox[1])
      case 270: return (y + cropBox[0], cropHeight - x + cropBox[1])
      default: return (x + cropBox[0], y + cropBox[1])
      }
    }
    let corners = [
      toPage(rect[0], rect[1]), toPage(rect[0], rect[3]),
      toPage(rect[2], rect[1]), toPage(rect[2], rect[3]),
    ]
    let xs = corners.map(\.0)
    let ys = corners.map(\.1)
    return [xs.min()!, ys.min()!, xs.max()!, ys.max()!]
  }
}

/// P26-004: rasterize the page as displayed (rotation and crop box applied)
/// at a bounded, measured resolution.
public enum OCRPageRasterizer {
  /// The long side target in pixels; small pages scale up to at most 4x and
  /// large pages scale down to this bound.
  public static let targetLongSide = 2200
  public static let maximumPixels = 40_000_000

  public static func rasterize(page: PDFPage) -> (image: CGImage, transform: OCRPageTransform)? {
    let crop = page.bounds(for: .cropBox)
    let rotation = page.rotation
    let displayWidth = rotation % 180 == 0 ? crop.width : crop.height
    let displayHeight = rotation % 180 == 0 ? crop.height : crop.width
    guard displayWidth > 1, displayHeight > 1 else { return nil }
    let scale = min(4, max(1, Double(targetLongSide) / Double(max(displayWidth, displayHeight))))
    let pixelWidth = Int((displayWidth * scale).rounded())
    let pixelHeight = Int((displayHeight * scale).rounded())
    guard pixelWidth > 0, pixelHeight > 0, pixelWidth * pixelHeight <= maximumPixels else {
      return nil
    }
    guard
      let context = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
        bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    context.scaleBy(x: scale, y: scale)
    page.draw(with: .cropBox, to: context)
    guard let image = context.makeImage() else { return nil }
    let transform = OCRPageTransform(
      imageWidth: Double(pixelWidth), imageHeight: Double(pixelHeight),
      cropBox: [
        Double(crop.minX), Double(crop.minY), Double(crop.maxX), Double(crop.maxY),
      ],
      rotation: rotation)
    return (image, transform)
  }
}

/// P26-007/P26-009: one recognized line with its page-space box.
public struct OCRTextLine: Sendable, Equatable {
  public let text: String
  public let rect: [Double]
  public let confidence: Double
}

public struct OCRPageResult: Sendable, Equatable {
  public let pageIndex: Int
  public let lines: [OCRTextLine]
}

/// P26-003/P26-018/P26-019/P26-020/P26-028: a local, sequential OCR job over
/// selected pages with progress and cancellation. It only reads the document
/// and returns results; nothing is committed until the caller applies them,
/// so cancellation always leaves a valid document.
public enum OCRJob {
  public static func run(
    document: PDFDocument, pageIndexes: [Int], languages: [String],
    level: OCRRecognitionLevel = .accurate, recognizer: TextRecognizing = VisionTextRecognizer(),
    onProgress: ((Int, Int) -> Void)? = nil
  ) throws -> [OCRPageResult] {
    var results: [OCRPageResult] = []
    let total = pageIndexes.count
    for (position, index) in pageIndexes.enumerated() {
      try Task.checkCancellation()
      guard index >= 0, index < document.pageCount, let page = document.page(at: index),
        let raster = OCRPageRasterizer.rasterize(page: page)
      else { continue }
      let observations = try recognizer.recognize(
        image: raster.image, languages: languages, level: level)
      results.append(
        OCRPageResult(
          pageIndex: index, lines: group(observations, transform: raster.transform)))
      onProgress?(position + 1, total)
    }
    return results
  }

  /// P26-008: defined reading order (top to bottom, then left to right) with
  /// one line per observation; empty or degenerate results are dropped.
  static func group(_ observations: [OCRObservation], transform: OCRPageTransform)
    -> [OCRTextLine]
  {
    let mapped = observations.compactMap { observation -> OCRTextLine? in
      let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      let rect = transform.pageRect(forNormalizedBox: observation.boundingBox)
      guard rect[2] > rect[0], rect[3] > rect[1] else { return nil }
      return OCRTextLine(text: text, rect: rect, confidence: observation.confidence)
    }
    return mapped.sorted { lhs, rhs in
      if abs(lhs.rect[3] - rhs.rect[3]) > 2 { return lhs.rect[3] > rhs.rect[3] }
      return lhs.rect[0] < rhs.rect[0]
    }
  }
}
