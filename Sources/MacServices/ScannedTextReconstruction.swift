import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFCore
import PDFEditing

/// OCR-05: one recognized word available for reconstruction. Rect is the
/// page-space box in points, derived from the generated layer line geometry.
public struct ScannedWord: Sendable, Equatable, Hashable {
  public let lineIndex: Int
  public let wordIndex: Int
  public let text: String
  public let rect: [Double]

  public init(lineIndex: Int, wordIndex: Int, text: String, rect: [Double]) {
    self.lineIndex = lineIndex
    self.wordIndex = wordIndex
    self.text = text
    self.rect = rect
  }
}

/// OCR-05: explicit refusals for unsupported paint or geometry. A refusal is
/// reported before any byte changes; nothing is applied silently.
public enum ScannedTextRefusal: Error, Equatable, CustomStringConvertible {
  case pageUnavailable(String)
  case noOCRText(String)
  case noScanImage(String)
  case ambiguousScanImage(String)
  case wordNotFound(String)
  case backgroundNotFlat(String)
  case textNotEncodable(String)
  case reconstructionUnsupported(String)
  case previewFailed(String)

  public var description: String {
    switch self {
    case .pageUnavailable(let reason), .noOCRText(let reason), .noScanImage(let reason),
      .ambiguousScanImage(let reason), .wordNotFound(let reason),
      .backgroundNotFlat(let reason), .textNotEncodable(let reason),
      .reconstructionUnsupported(let reason), .previewFailed(let reason):
      return reason
    }
  }

  public var message: String { description }
}

/// OCR-05: preview and evidence for one word. The after image is rendered from
/// the exact command the plan commits; the raster the command writes is kept so
/// tests can prove the saved scan equals the preview.
public struct ScannedTextPreview: Sendable, Equatable {
  public let pageIndex: Int
  public let pageID: PDFObjectID
  public let word: ScannedWord
  public let replacement: String
  public let beforePNG: Data?
  public let afterPNG: Data?
  public let replacementRaster: ScanRaster?
  public let layout: ScannedReplacementText?
  public let backgroundRGB: [Double]?
  public let erasedInkRatio: Double?
  public let visibleTextRunCountBefore: Int?
  public let refusal: ScannedTextRefusal?

  public var isSupported: Bool { refusal == nil }
}

/// OCR-05: a one-command plan. The transaction is atomic; committing it is one
/// Undo step and leaves the original image object intact for recovery.
public struct ScannedTextPlan {
  public let preview: ScannedTextPreview
  public let transaction: PDFTransaction?
  public let command: ReconstructScannedTextCommand?

  public init(
    preview: ScannedTextPreview, transaction: PDFTransaction?,
    command: ReconstructScannedTextCommand?
  ) {
    self.preview = preview
    self.transaction = transaction
    self.command = command
  }
}

/// OCR-05: editable scanned-text reconstruction.
public enum ScannedTextReconstructionService {
  /// Enumerate words from the generated searchable layer, in reading order.
  public static func words(
    pageIndex: Int, pageID: PDFObjectID, in graph: PDFGraph
  ) throws -> [ScannedWord] {
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    guard pageIndex >= 0, pageIndex < pageIDs.count, pageIDs[pageIndex] == pageID else {
      throw ScannedTextRefusal.pageUnavailable("The page is no longer at that position")
    }
    let lines: [ScannedTextLayerReader.Line]
    do {
      lines = try ScannedTextLayerReader.lines(pageID: pageID, in: graph)
    } catch {
      throw ScannedTextRefusal.noOCRText(
        "This page has no editable recognized text; run OCR for this page first")
    }
    var result: [ScannedWord] = []
    for (lineIndex, line) in lines.enumerated() {
      let words = ScannedTextLayerReader.words(in: line.text)
      guard !words.isEmpty else { continue }
      let totalUnits = max(1, line.text.utf16.count)
      let height = line.fontSize
      var offset = 0
      for (wordIndex, word) in words.enumerated() {
        // Reconstruct the word offset by scanning separators in reading order.
        let units = Array(line.text.utf16)
        while offset < units.count,
          UnicodeScalar(units[offset]).map({ CharacterSet.whitespaces.contains($0) }) ?? false
        {
          offset += 1
        }
        let length = word.utf16.count
        let lineWidth = line.searchableRect[2] - line.searchableRect[0]
        let x0 = line.x + Double(offset) / Double(totalUnits) * lineWidth
        let x1 = x0 + Double(length) / Double(totalUnits) * lineWidth
        result.append(
          ScannedWord(
            lineIndex: lineIndex, wordIndex: wordIndex, text: word,
            rect: [x0, line.y, x1, line.y + height]))
        offset += length
      }
    }
    return result
  }

  /// Build a preview without mutating the document.
  public static func preview(
    pageIndex: Int, pageID: PDFObjectID, word: ScannedWord, replacement: String,
    in graph: PDFGraph, previewPixelWidth: Int = 900
  ) -> ScannedTextPreview {
    do {
      let built = try build(
        pageIndex: pageIndex, pageID: pageID, word: word, replacement: replacement,
        in: graph, previewPixelWidth: previewPixelWidth)
      return built.preview
    } catch let refusal as ScannedTextRefusal {
      return failedPreview(
        pageIndex: pageIndex, pageID: pageID, word: word, replacement: replacement,
        refusal: refusal)
    } catch {
      return failedPreview(
        pageIndex: pageIndex, pageID: pageID, word: word, replacement: replacement,
        refusal: .reconstructionUnsupported(error.localizedDescription))
    }
  }

  /// Build the preview and the atomic transaction that would apply it.
  public static func plan(
    pageIndex: Int, pageID: PDFObjectID, word: ScannedWord, replacement: String,
    in graph: PDFGraph, previewPixelWidth: Int = 900
  ) -> ScannedTextPlan {
    let preview = preview(
      pageIndex: pageIndex, pageID: pageID, word: word, replacement: replacement,
      in: graph, previewPixelWidth: previewPixelWidth)
    guard preview.isSupported else {
      return ScannedTextPlan(preview: preview, transaction: nil, command: nil)
    }
    do {
      let command = try command(
        pageIndex: pageIndex, pageID: pageID, word: word, replacement: replacement,
        in: graph)
      return ScannedTextPlan(
        preview: preview, transaction: PDFTransaction([command]), command: command)
    } catch let refusal as ScannedTextRefusal {
      return ScannedTextPlan(
        preview: ScannedTextPreview(
          pageIndex: pageIndex, pageID: pageID, word: word, replacement: replacement,
          beforePNG: nil, afterPNG: nil, replacementRaster: nil, layout: nil,
          backgroundRGB: nil, erasedInkRatio: nil, visibleTextRunCountBefore: nil,
          refusal: refusal),
        transaction: nil, command: nil)
    } catch {
      return ScannedTextPlan(
        preview: ScannedTextPreview(
          pageIndex: pageIndex, pageID: pageID, word: word, replacement: replacement,
          beforePNG: nil, afterPNG: nil, replacementRaster: nil, layout: nil,
          backgroundRGB: nil, erasedInkRatio: nil, visibleTextRunCountBefore: nil,
          refusal: .reconstructionUnsupported(error.localizedDescription)),
        transaction: nil, command: nil)
    }
  }

  /// Build the command for an already-validated word. Exposed so callers can
  /// batch several reconstructions into one transaction (one Undo step).
  public static func command(
    pageIndex: Int, pageID: PDFObjectID, word: ScannedWord, replacement: String,
    in graph: PDFGraph
  ) throws -> ReconstructScannedTextCommand {
    try build(
      pageIndex: pageIndex, pageID: pageID, word: word, replacement: replacement,
      in: graph, previewPixelWidth: 240).command
  }

  struct Built {
    let preview: ScannedTextPreview
    let command: ReconstructScannedTextCommand
  }

  static func build(
    pageIndex: Int, pageID: PDFObjectID, word: ScannedWord, replacement: String,
    in graph: PDFGraph, previewPixelWidth: Int
  ) throws -> Built {
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    guard pageIndex >= 0, pageIndex < pageIDs.count, pageIDs[pageIndex] == pageID else {
      throw ScannedTextRefusal.pageUnavailable("The page is no longer at that position")
    }
    let trimmed = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ScannedTextRefusal.textNotEncodable("Enter a non-empty replacement word")
    }
    guard StandardTextFont.canEncode(trimmed) else {
      throw ScannedTextRefusal.textNotEncodable(
        "The standard fonts cannot draw these characters; choose Latin text")
    }
    let placements = try ImageInventory.placements(in: graph, pageID: pageID)
    guard !placements.isEmpty else {
      throw ScannedTextRefusal.noScanImage("The page has no scanned image to edit")
    }
    guard placements.count == 1 else {
      throw ScannedTextRefusal.ambiguousScanImage(
        "The page has several images; reconstruction needs one unambiguous scan")
    }
    let placement = placements[0]
    guard placement.depth == 0, placement.isDirectlyEditable,
      placement.hasSupportedClipping,
      abs(placement.localMatrix[1]) < 1e-9, abs(placement.localMatrix[2]) < 1e-9,
      abs(placement.localMatrix[0] - placement.localMatrix[3]) < 1e-6,
      placement.localMatrix[0] > 0
    else {
      throw ScannedTextRefusal.reconstructionUnsupported(
        "The scan is drawn inside a form, clip, rotation or shear that reconstruction does not support")
    }
    let mask = try ImageMaskState.describe(imageID: placement.imageID, in: graph)
    guard !mask.hasSMask, !mask.hasMask, !mask.isStencil, !mask.hasDecode else {
      throw ScannedTextRefusal.reconstructionUnsupported(
        "The scan uses a mask or decode array; reconstruction would not preserve it")
    }
    let raster = try ScanImageRaster.raster(imageID: placement.imageID, in: graph)
    let mapping = try ScannedTextPixelMapping.pixelRect(
      pageRect: word.rect, imageWidth: raster.width, imageHeight: raster.height,
      placementMatrix: placement.localMatrix)
    guard mapping.x1 - mapping.x0 >= 3, mapping.y1 - mapping.y0 >= 3 else {
      throw ScannedTextRefusal.wordNotFound("The recognized word box is too small to edit")
    }
    let padX = max(2, (mapping.x1 - mapping.x0) / 6)
    let padY = max(2, (mapping.y1 - mapping.y0) / 6)
    let inner = CGRect(x: mapping.x0, y: mapping.y0, width: mapping.x1 - mapping.x0, height: mapping.y1 - mapping.y0)
    let ring = ScanInkAnalysis.backgroundStats(raster, region: inner, ringWidth: 2)
    guard ring.spread <= 18 else {
      throw ScannedTextRefusal.backgroundNotFlat(
        "The background behind this word varies too much to erase cleanly")
    }
    let background = [ring.mean.0.rounded(), ring.mean.1.rounded(), ring.mean.2.rounded()]
    let eraseRect = CGRect(
      x: max(0, mapping.x0 - padX), y: max(0, mapping.y0 - padY),
      width: min(raster.width, mapping.x1 + padX) - max(0, mapping.x0 - padX),
      height: min(raster.height, mapping.y1 + padY) - max(0, mapping.y0 - padY))
    let beforeInk = ScanInkAnalysis.inkPixelCount(raster, region: eraseRect)
    var erased = raster
    let bounds = ScanInkAnalysis.clampedRegion(
      eraseRect, width: raster.width, height: raster.height)
    for y in bounds.minY..<bounds.maxY {
      for x in bounds.minX..<bounds.maxX {
        erased.setPixel(
          x: x, y: y, r: UInt8(max(0, min(255, background[0]))),
          g: UInt8(max(0, min(255, background[1]))),
          b: UInt8(max(0, min(255, background[2]))))
      }
    }
    let afterInk = ScanInkAnalysis.inkPixelCount(erased, region: eraseRect)
    let area = max(1, Int(eraseRect.width * eraseRect.height))
    let layout = try layoutReplacement(
      word: word, replacement: trimmed, background: background,
      placement: placement, raster: raster)
    let command = ReconstructScannedTextCommand(
      pageID: pageID, placementIndex: 0, ocrLineIndex: word.lineIndex,
      ocrWordIndex: word.wordIndex, originalWord: word.text, wordRect: word.rect,
      replacementImageWidth: erased.width, replacementImageHeight: erased.height,
      replacementRGB8: erased.rgb8, replacementText: layout)
    do {
      try command.validate(in: graph)
    } catch {
      throw ScannedTextRefusal.reconstructionUnsupported(
        error.localizedDescription)
    }
    let beforePNG = try ScanPageRenderer.pngData(
      graph: graph, pageIndex: pageIndex, pixelWidth: previewPixelWidth)
    let forecast: PDFGraph
    do {
      forecast = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
    } catch {
      throw ScannedTextRefusal.previewFailed(
        "The reconstructed preview could not be rendered: \(error.localizedDescription)")
    }
    let afterPNG = try ScanPageRenderer.pngData(
      graph: forecast, pageIndex: pageIndex, pixelWidth: previewPixelWidth)
    let visibleRuns = (try? PageTextEditing.sourceRuns(pageID: pageID, in: graph))?.count
    let preview = ScannedTextPreview(
      pageIndex: pageIndex, pageID: pageID, word: word, replacement: trimmed,
      beforePNG: beforePNG, afterPNG: afterPNG, replacementRaster: erased,
      layout: layout, backgroundRGB: background,
      erasedInkRatio: Double(beforeInk) / Double(area),
      visibleTextRunCountBefore: visibleRuns, refusal: nil)
    return Built(preview: preview, command: command)
  }

  static func layoutReplacement(
    word: ScannedWord, replacement: String, background: [Double],
    placement: ImagePlacement, raster: ScanRaster
  ) throws -> ScannedReplacementText {
    let width = word.rect[2] - word.rect[0]
    let height = word.rect[3] - word.rect[1]
    var fontSize = max(4, min(144, height * 0.82))
    let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    var advance = measure(replacement, font: font)
    if advance > width * 1.15, advance > 0 {
      fontSize = max(4, fontSize * (width * 1.15) / advance)
      advance = measure(replacement, font: CTFontCreateWithName(
        "Helvetica" as CFString, fontSize, nil))
    }
    guard fontSize >= 4, fontSize <= 144 else {
      throw ScannedTextRefusal.textNotEncodable(
        "The replacement word cannot be fitted into the erased box")
    }
    let baseline = word.rect[1] + height * 0.24
    let color = maxInkColor(raster: raster, word: word, placement: placement)
    _ = background
    return ScannedReplacementText(
      text: replacement, x: word.rect[0], baseline: baseline,
      fontSize: fontSize, font: .helvetica, color: color)
  }

  static func measure(_ text: String, font: CTFont) -> Double {
    let attributes: [NSAttributedString.Key: Any] = [.font: font]
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: text, attributes: attributes))
    return Double(CTLineGetTypographicBounds(line, nil, nil, nil))
  }

  /// Use the darkest sampled color inside the erased box for the replacement
  /// text so it matches the original scan ink; fall back to black.
  static func maxInkColor(
    raster: ScanRaster, word: ScannedWord, placement: ImagePlacement
  ) -> [Double] {
    guard let mapping = try? ScannedTextPixelMapping.pixelRect(
      pageRect: word.rect, imageWidth: raster.width, imageHeight: raster.height,
      placementMatrix: placement.localMatrix)
    else { return [0, 0, 0] }
    let bounds = ScanInkAnalysis.clampedRegion(
      CGRect(x: mapping.x0, y: mapping.y0, width: mapping.x1 - mapping.x0,
        height: mapping.y1 - mapping.y0),
      width: raster.width, height: raster.height)
    var darkest: (Int, Int, Int) = (0, 0, 0)
    var best = Double.infinity
    for y in bounds.minY..<bounds.maxY {
      for x in bounds.minX..<bounds.maxX {
        let (r, g, b) = raster.pixel(x: x, y: y)
        let luminance = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
        if luminance < best {
          best = luminance
          darkest = (Int(r), Int(g), Int(b))
        }
      }
    }
    if best > 140 { return [0, 0, 0] }
    return [
      Double(darkest.0) / 255.0, Double(darkest.1) / 255.0, Double(darkest.2) / 255.0,
    ]
  }

  static func failedPreview(
    pageIndex: Int, pageID: PDFObjectID, word: ScannedWord, replacement: String,
    refusal: ScannedTextRefusal
  ) -> ScannedTextPreview {
    ScannedTextPreview(
      pageIndex: pageIndex, pageID: pageID, word: word, replacement: replacement,
      beforePNG: nil, afterPNG: nil, replacementRaster: nil, layout: nil,
      backgroundRGB: nil, erasedInkRatio: nil, visibleTextRunCountBefore: nil,
      refusal: refusal)
  }
}