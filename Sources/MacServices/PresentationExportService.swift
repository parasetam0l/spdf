import CoreGraphics
import Foundation
import PDFCore
import PDFEditing

/// EXP-03: bounded PowerPoint reconstruction options.
public struct PresentationExportOptions: Sendable, Equatable {
  /// Resolution used when an image or a fallback page must be rendered.
  public var renderDPI: Double
  /// Upper bound on slides; pages beyond it are not exported.
  public var maxPages: Int
  /// Add a visible label to raster-fallback slides.
  public var includeFallbackLabel: Bool

  public init(renderDPI: Double = 150, maxPages: Int = 256, includeFallbackLabel: Bool = true) {
    self.renderDPI = max(36, min(renderDPI, 600))
    self.maxPages = max(1, maxPages)
    self.includeFallbackLabel = includeFallbackLabel
  }
}

/// EXP-03: build a PowerPoint export from the page-content reconstruction
/// inventories. Text runs with a supported transform become editable text
/// boxes, image placements become pictures (original JPEG bytes where usable,
/// rendered regions otherwise), and rectangle/line vector objects become
/// editable shapes. A page with any content outside that profile becomes one
/// clearly labelled raster image instead of silently dropping objects.
public enum PresentationExportService {
  /// The visible label a fallback slide always carries.
  public static let rasterFallbackLabel =
    "Raster fallback: this page was not reconstructed as editable content (not editable)."

  /// PowerPoint allows 56-inch slides; larger page sizes are scaled down.
  public static let maximumSlidePoints = 4_032.0

  public static func reconstruct(
    pageIDs: [PDFObjectID], in graph: PDFGraph, title: String,
    options: PresentationExportOptions = .init()
  ) throws -> PresentationExportDocument {
    var slides: [PresentationSlide] = []
    for (pageIndex, pageID) in pageIDs.prefix(options.maxPages).enumerated() {
      try Task.checkCancellation()
      let plan = try PresentationPageAnalyzer.analyze(
        pageIndex: pageIndex, pageID: pageID, in: graph)
      slides.append(try slide(from: plan, in: graph, options: options))
    }
    return PresentationExportDocument(slides: slides, title: title)
  }

  public static func write(
    _ document: PresentationExportDocument, to url: URL,
    zipLimits: ZIPArchiveWriter.Limits = .init()
  ) throws {
    let data = try PPTXExport.package(document: document, zipLimits: zipLimits)
    try data.write(to: url, options: .atomic)
  }

  // MARK: - Slide conversion

  static func slide(
    from plan: PresentationPagePlan, in graph: PDFGraph,
    options: PresentationExportOptions
  ) throws -> PresentationSlide {
    let scale = min(
      1, maximumSlidePoints / max(plan.size[0], plan.size[1], 1))
    let slideSize = [plan.size[0] * scale, plan.size[1] * scale]
    if plan.requiresRasterFallback {
      let data = try PageImageExport.imageData(
        pageID: plan.pageID, in: graph,
        options: PageImageExportOptions(format: .png, dpi: options.renderDPI))
      let element = PresentationImageElement(
        name: "page-\(plan.pageIndex + 1)-raster-fallback",
        bounds: [0, 0, slideSize[0], slideSize[1]], data: data,
        fileExtension: "png", provenance: .fullPageFallback,
        note: "Raster fallback: " + plan.unsupportedReasons.joined(separator: " "))
      return PresentationSlide(
        pageIndex: plan.pageIndex, size: slideSize, elements: [.image(element)],
        fallbackLabel: options.includeFallbackLabel ? rasterFallbackLabel : nil,
        notes: plan.unsupportedReasons)
    }

    var elements: [PresentationSlideElement] = []
    var notes: [String] = []
    var usedRenderedRegions = false
    for planned in plan.elements {
      switch planned {
      case .text(let text):
        let frame = slideFrame(text.bounds, plan: plan, scale: scale)
        elements.append(
          .text(
            PresentationTextElement(
              runs: [
                PresentationTextRun(
                  text: text.text, fontName: text.fontName,
                  fontSize: max(1, text.fontSize * scale), bold: text.bold,
                  italic: text.italic, colorHex: text.colorHex)
              ],
              bounds: frame, alignment: text.alignment,
              rotationDegrees: text.rotationDegrees)))
      case .image(let image):
        let frame = slideFrame(image.bounds, plan: plan, scale: scale)
        if image.canUseOriginalBytes {
          elements.append(
            .image(
              PresentationImageElement(
                name: image.name, bounds: frame, data: image.encodedData,
                fileExtension: "jpeg", provenance: .originalEncoded, note: image.note)))
        } else {
          let data = try PageImageExport.regionImageData(
            pageID: plan.pageID, in: graph, region: image.bounds,
            options: PageImageExportOptions(format: .png, dpi: options.renderDPI))
          usedRenderedRegions = true
          elements.append(
            .image(
              PresentationImageElement(
                name: image.name, bounds: frame, data: data, fileExtension: "png",
                provenance: .renderedRegion, note: image.note)))
        }
      case .shape(let shape):
        let frame = slideFrame(shape.bounds, plan: plan, scale: scale)
        elements.append(
          .shape(
            PresentationShapeElement(
              kind: shape.kind, bounds: frame, fillColorHex: shape.fillColorHex,
              strokeColorHex: shape.strokeColorHex,
              lineWidth: max(1, shape.lineWidth * scale), note: shape.note)))
      }
    }
    if usedRenderedRegions {
      notes.append(
        "Some images were rendered as regions because their stored bytes could not be "
          + "embedded directly; their appearance is preserved as editable pictures.")
    }
    if !elements.isEmpty {
      notes.append(
        "Text boxes and shapes are reconstructed from the page content; line wrapping and "
          + "font substitution may differ from the PDF.")
    }
    return PresentationSlide(
      pageIndex: plan.pageIndex, size: slideSize, elements: elements,
      fallbackLabel: nil, notes: notes)
  }

  /// Page coordinates (bottom-left, unrotated) to slide points (top-left),
  /// applying the page's CropBox and the slide-size scale.
  static func slideFrame(
    _ bounds: [Double], plan: PresentationPagePlan, scale: Double
  ) -> [Double] {
    guard bounds.count == 4, bounds.allSatisfy(\.isFinite) else { return [0, 0, 1, 1] }
    let crop = plan.cropBox
    let pageHeight = max(plan.size[1], 1)
    let x = (bounds[0] - crop[0]) * scale
    let y = (pageHeight - (bounds[3] - crop[1])) * scale
    let width = max(1, (bounds[2] - bounds[0]) * scale)
    let height = max(1, (bounds[3] - bounds[1]) * scale)
    return [x, y, x + width, y + height]
  }
}
