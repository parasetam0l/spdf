import AppKit
import CoreGraphics
import Foundation
import PDFCore
import PDFEditing
import PDFKit

/// PRE-08: advanced print export. Layout/order/clipping come from the owned
/// planner; this file only draws the planned sides. Export is
/// appearance-oriented (as the print pipeline always is) and makes no PDF/X
/// claim. Comments, when requested, are rendered from PDFKit annotation
/// appearances.
public struct PDFAdvancedPrintExportReport: Sendable, Equatable {
  public let plan: PDFAdvancedPrintPlan
  public let commentsDrawn: Bool
  public let warnings: [String]

  public var outputPageCount: Int { plan.outputPageCount }

  public func report() -> String {
    var lines = [plan.report()]
    lines.append(
      "Export: " + String(plan.outputPageCount) + " page(s); comments "
        + (commentsDrawn ? "drawn from annotation appearances." : "not drawn."))
    lines.append("Profile: appearance-oriented print output; no PDF/X conformance claim.")
    for warning in warnings { lines.append("  Export warning: " + warning) }
    return lines.joined(separator: "\n")
  }
}

@MainActor
public enum PDFAdvancedPrintExport {
  public static func writePDF(
    pageIDs: [PDFObjectID], in graph: PDFGraph, options: PDFAdvancedPrintOptions,
    to url: URL, limits: PDFLimits = PDFLimits()
  ) throws -> PDFAdvancedPrintExportReport {
    let (data, report) = try pdfData(
      pageIDs: pageIDs, in: graph, options: options, limits: limits)
    try data.write(to: url, options: .atomic)
    return report
  }

  public static func pdfData(
    pageIDs: [PDFObjectID], in graph: PDFGraph, options: PDFAdvancedPrintOptions,
    limits: PDFLimits = PDFLimits()
  ) throws -> (data: Data, report: PDFAdvancedPrintExportReport) {
    guard !pageIDs.isEmpty else {
      throw PDFError(.malformed, "No pages were selected for advanced printing")
    }
    let bytes = try PDFWriter.write(graph, limits: limits)
    guard let provider = CGDataProvider(data: bytes as CFData),
      let cgDocument = CGPDFDocument(provider)
    else {
      throw PDFError(.malformed, "The print source could not be opened")
    }
    let allPageIDs = try PDFPageTree.pageIDs(in: graph)
    var cgPages: [CGPDFPage] = []
    var pageBoxes: [[Double]] = []
    for pageID in pageIDs {
      guard let index = allPageIDs.firstIndex(of: pageID),
        let page = cgDocument.page(at: index + 1)
      else {
        throw PDFError(.malformed, "A selected print page is missing")
      }
      let fallback = page.getBoxRect(.cropBox)
      let box = Self.graphPageBox(graph: graph, pageID: pageID) ?? [
        Double(fallback.minX), Double(fallback.minY),
        Double(fallback.width), Double(fallback.height),
      ]
      guard box[2] > 0, box[3] > 0 else {
        throw PDFError(.malformed, "A selected print page has an empty crop box")
      }
      cgPages.append(page)
      pageBoxes.append(box)
    }
    let plan = try PDFAdvancedPrintPlanner.plan(pageBoxes: pageBoxes, options: options)
    guard plan.outputPageCount > 0 else {
      throw PDFError(.malformed, "The print layout produced no output pages")
    }
    let pdfDocument = options.includeComments ? PDFDocument(data: bytes) : nil
    var outputDocument = PDFDocument()
    var exportWarnings: [String] = []
    for side in plan.sides {
      let view = AdvancedPrintSideView(
        pages: cgPages, pdfPages: pdfDocument, placements: side.placements,
        includeComments: options.includeComments,
        paperSize: CGSize(width: side.paperSize[0], height: side.paperSize[1]))
      let data = NSMutableData()
      let operation = NSPrintOperation.pdfOperation(with: view, inside: view.bounds, to: data)
      let info = NSPrintInfo()
      info.paperSize = view.bounds.size
      info.topMargin = 0
      info.bottomMargin = 0
      info.leftMargin = 0
      info.rightMargin = 0
      info.isHorizontallyCentered = false
      info.isVerticallyCentered = false
      operation.printInfo = info
      operation.showsPrintPanel = false
      operation.showsProgressPanel = false
      guard operation.run() else {
        throw PDFError(.malformed, "The advanced print pipeline did not produce data")
      }
      guard let single = PDFDocument(data: data as Data), let page = single.page(at: 0) else {
        throw PDFError(.malformed, "The advanced print pipeline produced an unreadable page")
      }
      outputDocument.insert(page, at: outputDocument.pageCount)
    }
    guard outputDocument.pageCount == plan.outputPageCount else {
      throw PDFError(
        .malformed, "The advanced print pipeline produced the wrong page count")
    }
    if options.includeComments {
      exportWarnings.append(
        "Comments are drawn from PDFKit annotation appearances; JavaScript actions and "
          + "interactive widgets are flattened, as with any printed page.")
    }
    guard let data = outputDocument.dataRepresentation() else {
      throw PDFError(.malformed, "The advanced print PDF could not be encoded")
    }
    return (
      data,
      PDFAdvancedPrintExportReport(
        plan: plan, commentsDrawn: options.includeComments,
        warnings: plan.warnings + exportWarnings)
    )
  }

  /// Layout boxes come from the graph page dictionary so inherited/rotated
  /// CGPDF boxes cannot change the planned paper between verification runs.
  static func graphPageBox(graph: PDFGraph, pageID: PDFObjectID) -> [Double]? {
    guard case .dictionary(let page)? = graph.objects[pageID] else { return nil }
    for key in [PDFName("CropBox"), PDFName("MediaBox")] {
      guard case .array(let values)? = page[key] else { continue }
      let numbers = values.compactMap { value -> Double? in
        switch value {
        case .integer(let number): return Double(number)
        case .real(let number): return number
        default: return nil
        }
      }
      guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { continue }
      return numbers
    }
    return nil
  }
}

/// One planned output side. The print operation gives the view one page; the
/// view draws each placement with cropping and scale from the plan.
@MainActor
final class AdvancedPrintSideView: NSView {
  private let pages: [CGPDFPage]
  private let pdfPages: PDFDocument?
  private let placements: [PDFPrintPlacement]
  private let includeComments: Bool

  init(
    pages: [CGPDFPage], pdfPages: PDFDocument?, placements: [PDFPrintPlacement],
    includeComments: Bool, paperSize: CGSize
  ) {
    self.pages = pages
    self.pdfPages = pdfPages
    self.placements = placements
    self.includeComments = includeComments
    super.init(frame: NSRect(origin: .zero, size: paperSize))
  }

  required init?(coder: NSCoder) { nil }

  override var isFlipped: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(bounds)
    for placement in placements {
      guard placement.sourcePageIndex >= 0, placement.sourcePageIndex < pages.count else {
        continue
      }
      let page = pages[placement.sourcePageIndex]
      let target = rect(placement.targetRect)
      guard target.width > 0, target.height > 0 else { continue }
      context.saveGState()
      if let clip = placement.clipRect {
        context.clip(to: rect(clip))
      }
      if includeComments, let pdfPage = pdfPages?.page(at: placement.sourcePageIndex) {
        drawPdfKitPage(pdfPage, target: target, clip: placement.clipRect, in: context)
      } else {
        context.concatenate(
          page.getDrawingTransform(
            .cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
      }
      context.restoreGState()
    }
  }

  private func drawPdfKitPage(
    _ page: PDFPage, target: CGRect, clip: [Double]?, in context: CGContext
  ) {
    // PDFPage.draw draws page content and, when displaysAnnotations is true,
    // annotation appearances. The current CTM maps page space to output space.
    let box = page.bounds(for: .cropBox)
    guard box.width > 0, box.height > 0 else { return }
    let scale = min(target.width / box.width, target.height / box.height)
    context.saveGState()
    if let clip { context.clip(to: rect(clip)) }
    context.translateBy(
      x: target.minX + (target.width - box.width * scale) / 2,
      y: target.minY + (target.height - box.height * scale) / 2)
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -box.minX, y: -box.minY)
    page.displaysAnnotations = includeComments
    page.draw(with: .cropBox, to: context)
    context.restoreGState()
  }

  private func rect(_ values: [Double]) -> CGRect {
    guard values.count == 4 else { return .zero }
    return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
  }
}

/// PRE-07: raster flattening previews. CoreGraphics composites transparency
/// into the preview raster; overprint is not simulated. This is a review aid,
/// not a production flattener, and no PDF/X or ink-fidelity claim is made.
public struct PDFPrintPreviewReport: Sendable, Equatable {
  public let pageCount: Int
  public let dpi: Double
  public let files: [String]
  public let transparencyUses: Int
  public let overprintUses: Int
  public let spotColorNames: [String]
  public let disclosure: String
  public let warnings: [String]

  public func report() -> String {
    var lines = [
      "Flattening preview — " + String(pageCount) + " page(s) at "
        + String(format: "%.0f", dpi) + " dpi"
    ]
    lines.append(
      "Observed " + String(transparencyUses) + " transparency use(s), "
        + String(overprintUses) + " overprint state(s)"
        + (spotColorNames.isEmpty
          ? "." : ", spot colorants: " + spotColorNames.joined(separator: ", ") + "."))
    for file in files { lines.append("  " + file) }
    for warning in warnings { lines.append("  Warning: " + warning) }
    lines.append(disclosure)
    return lines.joined(separator: "\n")
  }
}

public enum PDFPrintPreviewExport {
  public static func writePNGPreviews(
    pageIDs: [PDFObjectID], in graph: PDFGraph, to directory: URL, dpi: Double = 72,
    limits: PDFLimits = PDFLimits()
  ) throws -> PDFPrintPreviewReport {
    guard !pageIDs.isEmpty else {
      throw PDFError(.malformed, "No pages were selected for a flattening preview")
    }
    guard dpi.isFinite, dpi >= 36, dpi <= 600 else {
      throw PDFError(.malformed, "The preview dpi is out of the supported range")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let inventory = PrintPreflightInventory.inventory(graph, pageIDs: pageIDs)
    let spot = SpotColorInventory.inventory(graph, pageIDs: pageIDs)
    var files: [String] = []
    for (index, pageID) in pageIDs.enumerated() {
      let options = PageImageExportOptions(format: .png, dpi: dpi, includeAlpha: false)
      let data = try PageImageExport.imageData(pageID: pageID, in: graph, options: options)
      let name = "flattening-preview-"
        + String(format: "%0(max(3, String(pageIDs.count).count))d", index + 1)
        + ".png"
      let url = directory.appendingPathComponent(name)
      try data.write(to: url, options: .atomic)
      files.append(name)
    }
    return PDFPrintPreviewReport(
      pageCount: pageIDs.count, dpi: dpi, files: files,
      transparencyUses: inventory.transparencyUses,
      overprintUses: inventory.overprintUses,
      spotColorNames: spot.spotNames,
      disclosure:
        "Raster appearance preview: transparency is composited by CoreGraphics; overprint "
        + "and spot ink simulation are not applied. This is not a production flattener and "
        + "does not create PDF/X output.",
      warnings: [
        "Overprint states are observed but not simulated; do not use this preview to judge "
          + "overprint appearance.",
        "Preview rasters are review-only; print/PDF output geometry is verified separately.",
      ])
  }
}

/// PRE-07: draw production marks (crop/registration/color-bar/job slug) around
/// planned pages. The marks layout is computed in PDFEditing; this exporter only
/// renders it.
@MainActor
public enum PDFProductionMarksExport {
  public static func writePDF(
    pageIDs: [PDFObjectID], in graph: PDFGraph, options: ProductionMarksOptions,
    to url: URL, limits: PDFLimits = PDFLimits()
  ) throws -> ProductionMarksLayout {
    let (data, layout) = try pdfData(
      pageIDs: pageIDs, in: graph, options: options, limits: limits)
    try data.write(to: url, options: .atomic)
    return layout
  }

  public static func pdfData(
    pageIDs: [PDFObjectID], in graph: PDFGraph, options: ProductionMarksOptions,
    limits: PDFLimits = PDFLimits()
  ) throws -> (data: Data, layout: ProductionMarksLayout) {
    guard !pageIDs.isEmpty else {
      throw PDFError(.malformed, "No pages were selected for production marks")
    }
    let bytes = try PDFWriter.write(graph, limits: limits)
    guard let provider = CGDataProvider(data: bytes as CFData),
      let cgDocument = CGPDFDocument(provider)
    else { throw PDFError(.malformed, "The marks source could not be opened") }
    let allPageIDs = try PDFPageTree.pageIDs(in: graph)
    var cgPages: [CGPDFPage] = []
    var inputs: [ProductionMarksPageInput] = []
    for pageID in pageIDs {
      guard let index = allPageIDs.firstIndex(of: pageID),
        let page = cgDocument.page(at: index + 1),
        case .dictionary(let dictionary)? = graph.objects[pageID]
      else { throw PDFError(.malformed, "A selected marks page is missing") }
      let box = page.getBoxRect(.mediaBox)
      cgPages.append(page)
      inputs.append(
        ProductionMarksPageInput(
          mediaBox: [
            Double(box.minX), Double(box.minY), Double(box.width), Double(box.height),
          ],
          trimBox: boxValues(dictionary[PDFName("TrimBox")]),
          bleedBox: boxValues(dictionary[PDFName("BleedBox")])))
    }
    let layout = try ProductionMarksPlanner.plan(pageInputs: inputs, options: options)
    var outputDocument = PDFDocument()
    for marksPage in layout.pages {
      guard marksPage.sourcePageIndex >= 0, marksPage.sourcePageIndex < cgPages.count else {
        throw PDFError(.malformed, "A production-marks page index is invalid")
      }
      let size = CGSize(width: marksPage.outputBox[2], height: marksPage.outputBox[3])
      let view = ProductionMarksPageView(
        page: cgPages[marksPage.sourcePageIndex],
        sourcePlacementRect: marksPage.sourcePlacementRect,
        marks: marksPage.marks, paperSize: size)
      let data = NSMutableData()
      let operation = NSPrintOperation.pdfOperation(with: view, inside: view.bounds, to: data)
      let info = NSPrintInfo()
      info.paperSize = size
      info.topMargin = 0
      info.bottomMargin = 0
      info.leftMargin = 0
      info.rightMargin = 0
      info.isHorizontallyCentered = false
      info.isVerticallyCentered = false
      operation.printInfo = info
      operation.showsPrintPanel = false
      operation.showsProgressPanel = false
      guard operation.run(),
        let single = PDFDocument(data: data as Data), let page = single.page(at: 0)
      else { throw PDFError(.malformed, "The production-marks pipeline failed") }
      outputDocument.insert(page, at: outputDocument.pageCount)
    }
    guard let data = outputDocument.dataRepresentation() else {
      throw PDFError(.malformed, "The production-marks PDF could not be encoded")
    }
    return (data, layout)
  }

  static func boxValues(_ value: PDFValue?) -> [Double]? {
    guard case .array(let values)? = value else { return nil }
    let numbers = values.compactMap { value -> Double? in
      switch value {
      case .integer(let number): return Double(number)
      case .real(let number): return number
      default: return nil
      }
    }
    return numbers.count == 4 ? numbers : nil
  }
}

@MainActor
final class ProductionMarksPageView: NSView {
  private let page: CGPDFPage
  private let sourcePlacementRect: [Double]
  private let marks: [ProductionMarkPrimitive]

  init(
    page: CGPDFPage, sourcePlacementRect: [Double], marks: [ProductionMarkPrimitive],
    paperSize: CGSize
  ) {
    self.page = page
    self.sourcePlacementRect = sourcePlacementRect
    self.marks = marks
    super.init(frame: NSRect(origin: .zero, size: paperSize))
  }

  required init?(coder: NSCoder) { nil }

  override var isFlipped: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(bounds)
    let placement = rect(sourcePlacementRect)
    if placement.width > 0, placement.height > 0 {
      context.saveGState()
      context.clip(to: placement)
      context.concatenate(
        page.getDrawingTransform(
          .cropBox, rect: placement, rotate: 0, preserveAspectRatio: true))
      context.drawPDFPage(page)
      context.restoreGState()
    }
    drawMarks(in: context)
  }

  private func drawMarks(in context: CGContext) {
    context.setStrokeColor(CGColor(gray: 0, alpha: 1))
    for mark in marks {
      switch mark {
      case .line(let x1, let y1, let x2, let y2, let width):
        context.setLineWidth(width)
        context.move(to: CGPoint(x: x1, y: y1))
        context.addLine(to: CGPoint(x: x2, y: y2))
        context.strokePath()
      case .rectangle(let x, let y, let width, let height):
        context.setFillColor(CGColor(gray: 0.85, alpha: 1))
        context.fill(CGRect(x: x, y: y, width: width, height: height))
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(0.5)
        context.stroke(CGRect(x: x, y: y, width: width, height: height))
      case .circle(let centerX, let centerY, let radius):
        context.setLineWidth(0.5)
        context.strokeEllipse(
          in: CGRect(
            x: centerX - radius, y: centerY - radius, width: 2 * radius, height: 2 * radius))
      case .text(let text, let x, let y, let size):
        let attributes: [NSAttributedString.Key: Any] = [
          .font: NSFont.systemFont(ofSize: size),
          .foregroundColor: NSColor.black,
        ]
        (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
      }
    }
  }

  private func rect(_ values: [Double]) -> CGRect {
    guard values.count == 4 else { return .zero }
    return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
  }
}
