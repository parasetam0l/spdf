import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import PDFCore
import PDFEditing
@preconcurrency import Vision

/// OCR-04: explicit, per-page scan cleanup settings. Every transform can be
/// turned off, and automatic values are reported before the user applies them.
public struct ScanCleanupOptions: Sendable, Equatable {
  public enum Deskew: Sendable, Equatable {
    case automatic
    case none
    case degrees(Double)
  }
  public enum Orientation: Sendable, Equatable {
    case automatic
    case none
    case quarterTurns(Int)
  }
  public enum Crop: Sendable, Equatable {
    case automaticMargins
    case none
    /// Page-space rectangle, bottom-left origin, in PDF points.
    case pageRect([Double])
  }

  public var deskew: Deskew
  public var orientation: Orientation
  public var crop: Crop
  public var contrast: Bool
  public var backgroundCleanup: Bool
  public var previewPixelWidth: Int

  public init(
    deskew: Deskew = .automatic, orientation: Orientation = .automatic,
    crop: Crop = .automaticMargins, contrast: Bool = true,
    backgroundCleanup: Bool = true, previewPixelWidth: Int = 900
  ) {
    self.deskew = deskew
    self.orientation = orientation
    self.crop = crop
    self.contrast = contrast
    self.backgroundCleanup = backgroundCleanup
    self.previewPixelWidth = max(120, min(2_000, previewPixelWidth))
  }
}

/// OCR-04: everything that can make cleanup refuse or lose content is an
/// explicit, reported reason rather than a silent partial result.
public enum ScanCleanupRefusal: Error, Equatable, CustomStringConvertible {
  case pageUnavailable(String)
  case noScanImage(String)
  case ambiguousScanImage(String)
  case unsupportedPaint(String)
  case imageUnavailable(String)
  case cropWouldRemoveContent(String)
  case orientationUndetermined(String)

  public var description: String {
    switch self {
    case .pageUnavailable(let reason): return reason
    case .noScanImage(let reason): return reason
    case .ambiguousScanImage(let reason): return reason
    case .unsupportedPaint(let reason): return reason
    case .imageUnavailable(let reason): return reason
    case .cropWouldRemoveContent(let reason): return reason
    case .orientationUndetermined(let reason): return reason
    }
  }

  public var message: String { description }
}

/// OCR-04: detectors run before the preview is built so the UI can show what
/// the automatic options decided for this page.
public struct ScanCleanupDetection: Sendable, Equatable {
  public let skewDegrees: Double
  public let orientationQuarterTurns: Int?
  /// Ink bounding box in normalized bottom-left image coordinates.
  public let contentRect: [Double]?
  public let inkPixelCount: Int
  public let backgroundSpread: Double

  public init(
    skewDegrees: Double, orientationQuarterTurns: Int?, contentRect: [Double]?,
    inkPixelCount: Int, backgroundSpread: Double
  ) {
    self.skewDegrees = skewDegrees
    self.orientationQuarterTurns = orientationQuarterTurns
    self.contentRect = contentRect
    self.inkPixelCount = inkPixelCount
    self.backgroundSpread = backgroundSpread
  }
}

/// OCR-04: what one applied page reports. The original image object is never
/// rewritten in place: the command creates a fresh instance and leaves the
/// source stream in the graph, so Undo and extraction can recover it.
public struct ScanCleanupReport: Sendable, Equatable {
  public let pageIndex: Int
  public let pageID: PDFObjectID
  public let originalImageID: PDFObjectID
  public let originalImageBytesHash: String
  public let appliedDeskewDegrees: Double
  public let appliedOrientationQuarterTurns: Int
  public let appliedCropRect: [Double]?
  public let inkPixelsBefore: Int
  public let inkPixelsAfter: Int
  public let outputWidth: Int
  public let outputHeight: Int
  /// True when the previous searchable layer was dropped because glyph
  /// positions changed; the UI tells the user to re-run OCR.
  public let searchableTextInvalidated: Bool
  public let warnings: [String]
}

/// OCR-04: preview and plan for one page. The cleaned raster is the byte-exact
/// payload the apply command writes, so the saved image equals the preview.
public struct ScanCleanupPagePreview: Sendable, Equatable {
  public let pageIndex: Int
  public let pageID: PDFObjectID
  public let detection: ScanCleanupDetection?
  public let beforePNG: Data?
  public let afterPNG: Data?
  public let cleanedRaster: ScanRaster?
  public let report: ScanCleanupReport?
  public let refusal: ScanCleanupRefusal?

  public var isSupported: Bool { refusal == nil }
}

/// OCR-04: a selective, one-transaction cleanup plan. Only supported pages
/// contribute commands; refused pages are reported and never touched.
public struct ScanCleanupPlan {
  public let previews: [ScanCleanupPagePreview]
  public let transaction: PDFTransaction?

  public var reports: [ScanCleanupReport] {
    previews.compactMap(\.report)
  }
  public var refusals: [(pageIndex: Int, pageID: PDFObjectID, refusal: ScanCleanupRefusal)] {
    previews.compactMap { preview in
      guard let refusal = preview.refusal else { return nil }
      return (preview.pageIndex, preview.pageID, refusal)
    }
  }
  public var cleanedPageIndices: [Int] { reports.map(\.pageIndex) }
}

/// OCR-04: optional replacement for the Vision-based orientation detector.
/// Tests inject a deterministic detector; production uses the Vision default.
public typealias ScanOrientationDetector = @Sendable (ScanRaster) -> Int?

/// OCR-04: pixel pipeline. Detectors and transforms are static and
/// deterministic so preview and apply cannot diverge.
public enum ScanCleanupProcessor {
  public static func detect(
    _ raster: ScanRaster, orientationDetector: ScanOrientationDetector? = nil
  ) throws -> ScanCleanupDetection {
    let skew = ScanInkAnalysis.estimateSkewDegrees(raster)
    let turns = (orientationDetector ?? ScanCleanupOrientationDetector.vision) (raster)
    let bounds = ScanInkAnalysis.inkBounds(raster)
    let contentRect: [Double]? = bounds.map { rect in
      [
        Double(rect.minX) / Double(raster.width), Double(rect.minY) / Double(raster.height),
        Double(rect.maxX) / Double(raster.width), Double(rect.maxY) / Double(raster.height),
      ]
    }
    let ink = ScanInkAnalysis.inkPixelCount(raster)
    let spread = bounds.map {
      ScanInkAnalysis.backgroundStats(raster, region: $0).spread
    } ?? 0
    return ScanCleanupDetection(
      skewDegrees: skew, orientationQuarterTurns: turns, contentRect: contentRect,
      inkPixelCount: ink, backgroundSpread: spread)
  }

  /// Produce the cleaned raster plus the values actually applied.
  public static func clean(
    _ raster: ScanRaster, options: ScanCleanupOptions,
    detection: ScanCleanupDetection, placementAspect: Double,
    placementMatrix: [Double]
  ) throws -> (raster: ScanRaster, deskew: Double, turns: Int, cropRect: [Double]?) {
    var current = raster
    var appliedTurns = 0
    switch options.orientation {
    case .none:
      break
    case .quarterTurns(let turns):
      appliedTurns = ((turns % 4) + 4) % 4
      current = try ScanImageTransform.rotateQuarterTurns(current, turns: appliedTurns)
    case .automatic:
      guard let detected = detection.orientationQuarterTurns else {
        throw ScanCleanupRefusal.orientationUndetermined(
          "The orientation could not be detected automatically; choose a rotation explicitly")
      }
      appliedTurns = ((detected % 4) + 4) % 4
      current = try ScanImageTransform.rotateQuarterTurns(current, turns: appliedTurns)
    }

    var appliedDeskew = 0.0
    switch options.deskew {
    case .none:
      break
    case .degrees(let degrees):
      let clamped = max(-15, min(15, degrees))
      appliedDeskew = clamped
      current = try ScanImageTransform.deskewed(current, degrees: clamped)
    case .automatic:
      // The detector ran on the original orientation; re-detect after a
      // quarter-turn so the angle stays meaningful for the rotated content.
      let skew = abs(detection.skewDegrees) > 15
        ? 0 : ScanInkAnalysis.estimateSkewDegrees(current)
      if abs(skew) >= 0.35 {
        appliedDeskew = skew
        current = try ScanImageTransform.deskewed(current, degrees: skew)
      }
    }

    var appliedCrop: [Double]?
    switch options.crop {
    case .none:
      break
    case .automaticMargins:
      if let bounds = ScanInkAnalysis.inkBounds(current) {
        let marginX = max(12, Int(Double(current.width) * 0.02))
        let marginY = max(12, Int(Double(current.height) * 0.02))
        let rect = CGRect(
          x: max(0, bounds.minX - CGFloat(marginX)),
          y: max(0, bounds.minY - CGFloat(marginY)),
          width: min(CGFloat(current.width), bounds.width + CGFloat(2 * marginX)),
          height: min(CGFloat(current.height), bounds.height + CGFloat(2 * marginY)))
        appliedCrop = [
          Double(rect.minX), Double(rect.minY), Double(rect.maxX), Double(rect.maxY),
        ]
        current = try ScanImageTransform.cropped(current, to: rect)
      }
    case .pageRect(let pageRect):
      guard pageRect.count == 4, pageRect[2] > pageRect[0], pageRect[3] > pageRect[1] else {
        throw ScanCleanupRefusal.cropWouldRemoveContent(
          "The crop rectangle is not a valid page rectangle")
      }
      let pixelRect = try Self.pixelRect(
        forPageRect: pageRect, raster: current, placementAspect: placementAspect,
        placementMatrix: placementMatrix)
      if let ink = ScanInkAnalysis.inkBounds(current),
        !pixelRect.contains(ink)
      {
        throw ScanCleanupRefusal.cropWouldRemoveContent(
          "The crop would cut scanned ink; move the rectangle outward or use automatic margins")
      }
      appliedCrop = [
        Double(pixelRect.minX), Double(pixelRect.minY),
        Double(pixelRect.maxX), Double(pixelRect.maxY),
      ]
      current = try ScanImageTransform.cropped(current, to: pixelRect)
    }

    if options.contrast {
      current = try ScanImageTransform.autoContrast(current)
    }
    if options.backgroundCleanup {
      current = try ScanImageTransform.flattenedBackground(current)
    }
    current = try ScanImageTransform.fittedToAspect(current, aspect: placementAspect)

    let beforeInk = ScanInkAnalysis.inkPixelCount(raster)
    let afterInk = ScanInkAnalysis.inkPixelCount(current)
    if beforeInk > 200, afterInk < Int(Double(beforeInk) * 0.55) {
      throw ScanCleanupRefusal.cropWouldRemoveContent(
        "The cleanup would remove most of the scanned ink; reduce the crop or contrast")
    }
    return (current, appliedDeskew, appliedTurns, appliedCrop)
  }

  /// Map a page-space rectangle onto the scan raster. Only axis-aligned,
  /// uniformly scaled placements are supported by the cleanup profile.
  public static func pixelRect(
    forPageRect pageRect: [Double], raster: ScanRaster, placementAspect: Double,
    placementMatrix: [Double]
  ) throws -> CGRect {
    guard placementMatrix.count == 6,
      abs(placementMatrix[1]) < 1e-9, abs(placementMatrix[2]) < 1e-9,
      abs(placementMatrix[0] - placementMatrix[3]) < 1e-6,
      placementMatrix[0] > 0
    else {
      throw ScanCleanupRefusal.unsupportedPaint(
        "The scan is rotated or sheared on the page; crop cleanup needs an axis-aligned image")
    }
    let originX = placementMatrix[4]
    let originY = placementMatrix[5]
    let width = placementMatrix[0]
    let height = placementMatrix[3]
    guard width > 0, height > 0 else {
      throw ScanCleanupRefusal.unsupportedPaint("The scan placement has no visible size")
    }
    let left = (pageRect[0] - originX) / width
    let bottom = (pageRect[1] - originY) / height
    let right = (pageRect[2] - originX) / width
    let top = (pageRect[3] - originY) / height
    guard left >= -1e-6, bottom >= -1e-6, right <= 1 + 1e-6, top <= 1 + 1e-6,
      right > left, top > bottom
    else {
      throw ScanCleanupRefusal.cropWouldRemoveContent(
        "The crop rectangle extends past the scan image")
    }
    let x0 = max(0, min(raster.width, Int((left * Double(raster.width)).rounded())))
    let x1 = max(0, min(raster.width, Int((right * Double(raster.width)).rounded())))
    let y0 = max(0, min(raster.height, Int((bottom * Double(raster.height)).rounded())))
    let y1 = max(0, min(raster.height, Int((top * Double(raster.height)).rounded())))
    guard x1 - x0 > 16, y1 - y0 > 16 else {
      throw ScanCleanupRefusal.cropWouldRemoveContent(
        "The crop rectangle is too small to be useful")
    }
    return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
  }
}

/// OCR-04: document-level preview and selective application.
public enum ScanCleanupService {
  public static func pageIDs(in graph: PDFGraph) throws -> [PDFObjectID] {
    try PDFPageTree.pageIDs(in: graph)
  }

  public static func preview(
    pageIndex: Int, pageID: PDFObjectID, in graph: PDFGraph,
    options: ScanCleanupOptions, orientationDetector: ScanOrientationDetector? = nil
  ) -> ScanCleanupPagePreview {
    do {
      let result = try buildPage(
        pageIndex: pageIndex, pageID: pageID, in: graph, options: options,
        orientationDetector: orientationDetector)
      let afterPNG: Data
      do {
        let forecastGraph = try PDFEditingEngine.commit(
          PDFTransaction([result.command]), to: graph)
        afterPNG = try ScanPageRenderer.pngData(
          graph: forecastGraph, pageIndex: pageIndex,
          pixelWidth: options.previewPixelWidth)
      } catch let error as ScanCleanupRefusal {
        throw error
      } catch {
        throw ScanCleanupRefusal.imageUnavailable(
          "The cleaned preview could not be rendered: \(error.localizedDescription)")
      }
      let beforePNG = try ScanPageRenderer.pngData(
        graph: graph, pageIndex: pageIndex, pixelWidth: options.previewPixelWidth)
      return ScanCleanupPagePreview(
        pageIndex: pageIndex, pageID: pageID, detection: result.detection,
        beforePNG: beforePNG, afterPNG: afterPNG, cleanedRaster: result.cleaned,
        report: result.report, refusal: nil)
    } catch let refusal as ScanCleanupRefusal {
      return ScanCleanupPagePreview(
        pageIndex: pageIndex, pageID: pageID, detection: nil, beforePNG: nil,
        afterPNG: nil, cleanedRaster: nil, report: nil, refusal: refusal)
    } catch {
      return ScanCleanupPagePreview(
        pageIndex: pageIndex, pageID: pageID, detection: nil, beforePNG: nil,
        afterPNG: nil, cleanedRaster: nil, report: nil,
        refusal: .imageUnavailable(error.localizedDescription))
    }
  }

  /// Build a plan for the selected page indices. Refused pages are reported
  /// individually; the transaction contains only the supported pages.
  public static func plan(
    pageIndices: [Int], in graph: PDFGraph, options: ScanCleanupOptions,
    orientationDetector: ScanOrientationDetector? = nil
  ) -> ScanCleanupPlan {
    let pageIDs = (try? PDFPageTree.pageIDs(in: graph)) ?? []
    var previews: [ScanCleanupPagePreview] = []
    var commands: [ApplyScanCleanupCommand] = []
    for pageIndex in Array(Set(pageIndices)).sorted() {
      guard pageIndex >= 0, pageIndex < pageIDs.count else {
        previews.append(
          ScanCleanupPagePreview(
            pageIndex: pageIndex, pageID: PDFObjectID(0), detection: nil,
            beforePNG: nil, afterPNG: nil, cleanedRaster: nil, report: nil,
            refusal: .pageUnavailable("Page \(pageIndex + 1) does not exist")))
        continue
      }
      let preview = preview(
        pageIndex: pageIndex, pageID: pageIDs[pageIndex], in: graph,
        options: options, orientationDetector: orientationDetector)
      previews.append(preview)
    }
    for preview in previews where preview.report != nil {
      if let command = try? pageCommand(from: preview, in: graph) {
        commands.append(command)
      }
    }
    let transaction = commands.isEmpty ? nil : PDFTransaction(commands)
    return ScanCleanupPlan(previews: previews, transaction: transaction)
  }

  public static func pageCommand(
    from preview: ScanCleanupPagePreview, in graph: PDFGraph
  ) throws -> ApplyScanCleanupCommand {
    guard let raster = preview.cleanedRaster, let report = preview.report else {
      throw ScanCleanupRefusal.pageUnavailable("The page has no cleaned preview")
    }
    return ApplyScanCleanupCommand(
      pageID: preview.pageID, placementIndex: 0, width: raster.width,
      height: raster.height, rgb8: raster.rgb8)
  }
}

extension ScanCleanupService {
  struct BuiltPage {
    let detection: ScanCleanupDetection
    let cleaned: ScanRaster
    let command: ApplyScanCleanupCommand
    let report: ScanCleanupReport
  }

  static func buildPage(
    pageIndex: Int, pageID: PDFObjectID, in graph: PDFGraph,
    options: ScanCleanupOptions, orientationDetector: ScanOrientationDetector?
  ) throws -> BuiltPage {
    let placements = try ImageInventory.placements(in: graph, pageID: pageID)
    guard !placements.isEmpty else {
      throw ScanCleanupRefusal.noScanImage(
        "Page \(pageIndex + 1) has no scanned image to clean up")
    }
    guard placements.count == 1 else {
      throw ScanCleanupRefusal.ambiguousScanImage(
        "Page \(pageIndex + 1) has \(placements.count) images; cleanup needs one unambiguous scan")
    }
    let placement = placements[0]
    guard placement.depth == 0, placement.isDirectlyEditable, placement.hasSupportedClipping
    else {
      throw ScanCleanupRefusal.unsupportedPaint(
        "The scan is drawn inside a form or clipping; that paint is not supported by cleanup")
    }
    let mask = try ImageMaskState.describe(imageID: placement.imageID, in: graph)
    guard !mask.hasSMask, !mask.hasMask, !mask.isStencil, !mask.hasDecode else {
      throw ScanCleanupRefusal.unsupportedPaint(
        "The scan uses a mask or decode array; cleanup would not preserve it")
    }
    let raster = try ScanImageRaster.raster(imageID: placement.imageID, in: graph)
    let pageBounds = try pageBounds(pageID: pageID, in: graph)
    guard placement.bounds.count == 4, placement.bounds[2] > placement.bounds[0],
      placement.bounds[3] > placement.bounds[1]
    else {
      throw ScanCleanupRefusal.unsupportedPaint("The scan placement has no visible bounds")
    }
    let placementWidth = placement.bounds[2] - placement.bounds[0]
    let placementHeight = placement.bounds[3] - placement.bounds[1]
    guard placementWidth > 1, placementHeight > 1 else {
      throw ScanCleanupRefusal.unsupportedPaint("The scan placement is too small to clean up")
    }
    let aspect = placementWidth / placementHeight
    let detection = try ScanCleanupProcessor.detect(
      raster, orientationDetector: orientationDetector)
    let cleaned = try ScanCleanupProcessor.clean(
      raster, options: options, detection: detection, placementAspect: aspect,
      placementMatrix: placement.localMatrix)
    let report = ScanCleanupReport(
      pageIndex: pageIndex, pageID: pageID, originalImageID: placement.imageID,
      originalImageBytesHash: hash(try ScanImageRaster.originalBytes(
        imageID: placement.imageID, in: graph)),
      appliedDeskewDegrees: cleaned.deskew,
      appliedOrientationQuarterTurns: cleaned.turns,
      appliedCropRect: cleaned.cropRect,
      inkPixelsBefore: detection.inkPixelCount,
      inkPixelsAfter: ScanInkAnalysis.inkPixelCount(cleaned.raster),
      outputWidth: cleaned.raster.width, outputHeight: cleaned.raster.height,
      searchableTextInvalidated: OCRLayer.hasGeneratedLayer(in: graph, pageID: pageID),
      warnings: warnings(
        detection: detection, cleaned: cleaned.raster, placement: placement,
        pageBounds: pageBounds))
    let command = ApplyScanCleanupCommand(
      pageID: pageID, placementIndex: 0, width: cleaned.raster.width,
      height: cleaned.raster.height, rgb8: cleaned.raster.rgb8)
    return BuiltPage(
      detection: detection, cleaned: cleaned.raster, command: command, report: report)
  }

  static func warnings(
    detection: ScanCleanupDetection, cleaned: ScanRaster,
    placement: ImagePlacement, pageBounds: [Double]
  ) -> [String] {
    var warnings: [String] = []
    if let turns = detection.orientationQuarterTurns, turns % 4 != 0 {
      warnings.append("The scan was rotated by \((turns % 4) * 90) degrees")
    }
    if abs(detection.skewDegrees) > 0.35 {
      warnings.append(
        "Detected a \(String(format: "%.1f", detection.skewDegrees)) degree skew")
    }
    let coversPage = placement.bounds[0] <= pageBounds[0] + 1
      && placement.bounds[1] <= pageBounds[1] + 1
      && placement.bounds[2] >= pageBounds[2] - 1
      && placement.bounds[3] >= pageBounds[3] - 1
    if !coversPage {
      warnings.append("The scan does not cover the whole page; only the image is cleaned")
    }
    if detection.backgroundSpread > 26 {
      warnings.append(
        "The scan background varies; contrast or background cleanup may be uneven")
    }
    return warnings
  }

  static func pageBounds(pageID: PDFObjectID, in graph: PDFGraph) throws -> [Double] {
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw ScanCleanupRefusal.pageUnavailable("The page is missing")
    }
    guard case .array(let values)? = page[PDFName("MediaBox")], values.count == 4 else {
      return [0, 0, 612, 792]
    }
    var numbers: [Double] = []
    for value in values {
      switch value {
      case .integer(let int): numbers.append(Double(int))
      case .real(let real): numbers.append(real)
      default: return [0, 0, 612, 792]
      }
    }
    guard numbers.count == 4, numbers[2] > numbers[0], numbers[3] > numbers[1] else {
      return [0, 0, 612, 792]
    }
    return numbers
  }

  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

/// OCR-04: Vision-based orientation detection. It recognizes all four
/// quarter turns and picks the one with the most recognized characters; when
/// Vision is unavailable the caller must choose the rotation explicitly.
public enum ScanCleanupOrientationDetector {
  public static let vision: ScanOrientationDetector = { raster in
    try? bestQuarterTurns(raster)
  }

  public static func bestQuarterTurns(_ raster: ScanRaster) throws -> Int? {
    var bestTurns: Int?
    var bestScore = 0
    for turns in [0, 1, 2, 3] {
      guard let rotated = try? ScanImageTransform.rotateQuarterTurns(raster, turns: turns),
        let image = rotated.cgImage()
      else { continue }
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .fast
      request.usesLanguageCorrection = false
      let handler = VNImageRequestHandler(cgImage: image, options: [:])
      do {
        try handler.perform([request])
      } catch {
        continue
      }
      let observations = request.results ?? []
      let score = observations.reduce(0) { $0 + ($1.topCandidates(1).first?.string.count ?? 0) }
      if score > bestScore {
        bestScore = score
        bestTurns = turns
      }
    }
    guard bestScore >= 8 else { return nil }
    return bestTurns
  }
}
