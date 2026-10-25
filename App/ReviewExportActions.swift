import AppKit
import PDFCore
import PDFEditing
import PDFKit
import UniformTypeIdentifiers

// MARK: - Page rendering for portable reports

/// Renders pages and change-region crops for the printable reports. Rendering
/// stays in the App layer; the PDFEditing report builders only receive pixels
/// so their output structure is deterministic and testable without a renderer.
enum ReviewReportRenderer {
  static let defaultMaxPixelWidth = 800
  static let defaultMaxPixelHeight = 1_100
  static let defaultMaxPixels = 1_300_000

  static func rasterImage(
    page: CGPDFPage, maxPixelWidth: Int = defaultMaxPixelWidth,
    maxPixelHeight: Int = defaultMaxPixelHeight, maxPixels: Int = defaultMaxPixels
  ) throws -> ReportRasterImage {
    let box = page.getBoxRect(.cropBox)
    let rotation = Int(page.rotationAngle)
    let display = ReportPageGeometry.displaySize(
      displayBox: [box.minX, box.minY, box.maxX, box.maxY], rotation: rotation)
    guard display[0] > 0, display[1] > 0 else {
      throw PDFError(.malformed, "A report page has no drawable area")
    }
    let scale = min(
      Double(max(1, maxPixelWidth)) / display[0],
      min(
        Double(max(1, maxPixelHeight)) / display[1],
        (Double(max(1, maxPixels)) / (display[0] * display[1])).squareRoot()))
    let width = max(1, Int((display[0] * scale).rounded(.down)))
    let height = max(1, Int((display[1] * scale).rounded(.down)))
    guard width <= 4_000, height <= 5_000, width * height <= maxPixels else {
      throw PDFError(.limitExceeded, "A report page render exceeds the pixel budget")
    }
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
      data: &rgba, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
      throw PDFError(.unsupported, "The report page renderer could not create a bitmap context")
    }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let transform = page.getDrawingTransform(
      .cropBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0,
      preserveAspectRatio: true)
    context.concatenate(transform)
    context.drawPDFPage(page)
    var rgb = [UInt8](repeating: 255, count: width * height * 3)
    for pixel in 0..<(width * height) {
      let source = pixel * 4
      let target = pixel * 3
      rgb[target] = rgba[source]
      rgb[target + 1] = rgba[source + 1]
      rgb[target + 2] = rgba[source + 2]
    }
    return ReportRasterImage(width: width, height: height, rgb8: Data(rgb))
  }

  static func rasterImage(
    document: PDFDocument, pageIndex: Int,
    maxPixelWidth: Int = defaultMaxPixelWidth,
    maxPixelHeight: Int = defaultMaxPixelHeight,
    maxPixels: Int = defaultMaxPixels
  ) throws -> ReportRasterImage {
    guard let page = document.page(at: pageIndex + 1), let pageRef = page.pageRef else {
      throw PDFError(.malformed, "A report page is missing from the document")
    }
    return try rasterImage(
      page: pageRef, maxPixelWidth: maxPixelWidth, maxPixelHeight: maxPixelHeight,
      maxPixels: maxPixels)
  }

  static func rasterImage(
    pdfData: Data, pageIndex: Int, maxPixelWidth: Int = defaultMaxPixelWidth,
    maxPixelHeight: Int = defaultMaxPixelHeight, maxPixels: Int = defaultMaxPixels
  ) throws -> ReportRasterImage {
    guard let provider = CGDataProvider(data: pdfData as CFData),
      let document = CGPDFDocument(provider),
      let page = document.page(at: pageIndex + 1)
    else {
      throw PDFError(.malformed, "The report source could not be rendered")
    }
    return try rasterImage(
      page: page, maxPixelWidth: maxPixelWidth, maxPixelHeight: maxPixelHeight,
      maxPixels: maxPixels)
  }

  /// Render one page and crop the region around a page-space rectangle. The
  /// region is clipped to the visible page; returns nil when the region has no
  /// drawable overlap.
  static func regionImage(
    page: CGPDFPage, contentRect: [Double],
    maxPixelWidth: Int = 900, maxPixelHeight: Int = 1_200,
    maxPixels: Int = 2_500_000
  ) throws -> ReportRasterImage? {
    guard contentRect.count == 4 else { return nil }
    let box = page.getBoxRect(.cropBox)
    let displayBox: [Double] = [
      Double(box.minX), Double(box.minY), Double(box.maxX), Double(box.maxY),
    ]
    let rotation = Int(page.rotationAngle)
    let displaySize = ReportPageGeometry.displaySize(
      displayBox: displayBox, rotation: rotation)
    let displayRect = ReportPageGeometry.displayRect(
      forContentRect: contentRect, displayBox: displayBox, rotation: rotation)
    let padded = [
      max(0, displayRect[0] - 8), max(0, displayRect[1] - 8),
      min(displaySize[0], displayRect[2] + 8), min(displaySize[1], displayRect[3] + 8),
    ]
    guard padded[2] - padded[0] > 0.5, padded[3] - padded[1] > 0.5 else { return nil }
    let full = try rasterImage(
      page: page, maxPixelWidth: maxPixelWidth, maxPixelHeight: maxPixelHeight,
      maxPixels: maxPixels)
    let u0 = padded[0] / displaySize[0]
    let v0 = padded[1] / displaySize[1]
    let u1 = padded[2] / displaySize[0]
    let v1 = padded[3] / displaySize[1]
    let x0 = max(0, min(full.width - 1, Int((u0 * Double(full.width)).rounded(.down))))
    let x1 = max(x0 + 1, min(full.width, Int((u1 * Double(full.width)).rounded(.up))))
    // PDF images store the first row at the top, so the display-space bottom
    // edge becomes the largest pixel row.
    let y0 = max(0, min(full.height - 1, Int(((1 - v1) * Double(full.height)).rounded(.down))))
    let y1 = max(y0 + 1, min(full.height, Int(((1 - v0) * Double(full.height)).rounded(.up))))
    let cropWidth = x1 - x0
    let cropHeight = y1 - y0
    guard cropWidth >= 2, cropHeight >= 2 else { return nil }
    var cropped = [UInt8](repeating: 255, count: cropWidth * cropHeight * 3)
    let fullBytes = [UInt8](full.rgb8)
    for row in 0..<cropHeight {
      let sourceStart = ((y0 + row) * full.width + x0) * 3
      let targetStart = row * cropWidth * 3
      cropped.replaceSubrange(
        targetStart..<(targetStart + cropWidth * 3),
        with: fullBytes[sourceStart..<(sourceStart + cropWidth * 3)])
    }
    return ReportRasterImage(width: cropWidth, height: cropHeight, rgb8: Data(cropped))
  }

  static func regionImage(
    document: PDFDocument, pageIndex: Int, contentRect: [Double]
  ) throws -> ReportRasterImage? {
    guard let page = document.page(at: pageIndex + 1), let pageRef = page.pageRef else {
      return nil
    }
    return try regionImage(page: pageRef, contentRect: contentRect)
  }
}

// MARK: - Review/report services and menu hooks

extension SPDFDocument {
  // MARK: Review summary

  var canExportReviewSummaryReport: Bool {
    editSession.currentGraph != nil && !editSession.pageIDs.isEmpty
  }

  var canExportComparisonReport: Bool {
    comparisonSession != nil
  }

  var canShowReviewReports: Bool { true }

  /// Tools -> Review Reports...: the printable review-summary and comparison
  /// report panel.
  func showReviewReports() {
    if let controller = windowControllers.compactMap({
      $0 as? ReviewReportsPanelController
    }).first {
      controller.refresh()
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = ReviewReportsPanelController(document: self)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  /// File -> Export -> Export Review Summary (PDF)... (direct menu route).
  func exportReviewSummaryPDF() {
    presentReviewSummaryExport(
      options: ReviewSummaryOptions(
        sourceDescription: fileURL?.lastPathComponent,
        documentRevision: editSession.documentRevision,
        generatedOn: Self.reviewReportTimestamp()))
  }

  func presentReviewSummaryExport(
    options: ReviewSummaryOptions,
    completion: ((String?, Error?) -> Void)? = nil
  ) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.nameFieldStringValue =
      (fileURL?.deletingPathExtension().lastPathComponent ?? "document")
      + "-review-summary.pdf"
    panel.begin { [weak self] response in
      guard let self else { return }
      guard response == .OK, let url = panel.url else {
        completion?(nil, nil)
        return
      }
      do {
        var options = options
        if options.generatedOn == nil || options.generatedOn?.isEmpty == true {
          options.generatedOn = Self.reviewReportTimestamp()
        }
        let report = try self.writeReviewSummaryPDF(to: url, options: options)
        completion?(report.summary, nil)
        let alert = NSAlert()
        alert.messageText = "Review Summary Exported"
        alert.informativeText = report.summary
        alert.addButton(withTitle: "OK")
        alert.runModal()
      } catch {
        completion?(nil, error)
        self.presentError(error)
      }
    }
  }

  /// Build and write a review-summary PDF. The report reflects the current
  /// review state (canonical graph) at the document revision recorded in the
  /// options; nothing in the source document is mutated.
  @discardableResult
  func writeReviewSummaryPDF(
    to url: URL, options: ReviewSummaryOptions
  ) throws -> ReviewSummaryReport {
    guard let graph = editSession.currentGraph else {
      throw PDFError(.unsupported, "This document is not editable by the owned core")
    }
    guard let data = try? editSession.bytesForSave() else {
      throw PDFError(.malformed, "The document bytes could not be produced for the report")
    }
    var pageImages: [ReviewSummaryPageImage] = []
    if options.includePageImages {
      let pages = Self.reviewSummaryPageIndexes(graph: graph, options: options)
      guard pages.count <= 60 else {
        throw PDFError(
          .limitExceeded,
          "This report would render \(pages.count) page images; filter the report to 60 pages or fewer.")
      }
      guard let document = PDFDocument(data: data) else {
        throw PDFError(.malformed, "The report source could not be rendered")
      }
      for pageIndex in pages {
        guard let image = try? ReviewReportRenderer.rasterImage(
          document: document, pageIndex: pageIndex) else { continue }
        pageImages.append(ReviewSummaryPageImage(pageIndex: pageIndex, image: image))
      }
    }
    let report = try ReviewSummaryReportBuilder.build(
      graph: graph, pageIDs: editSession.pageIDs, pageImages: pageImages,
      options: options, limits: SPDFDocumentResourcePolicy.parsingLimits)
    try report.data.write(to: url, options: .atomic)
    return report
  }

  /// Pages that will get page-context images: those with included comments,
  /// preserving page order and applying the same filters as the report.
  static func reviewSummaryPageIndexes(
    graph: PDFGraph, options: ReviewSummaryOptions
  ) -> [Int] {
    let pageIDs = try? PDFPageTree.pageIDs(in: graph)
    guard let pageIDs else { return [] }
    var comments = CommentList.comments(in: graph, pageIDs: pageIDs)
    if let pages = options.pageIndices {
      comments = comments.filter { pages.contains($0.pageIndex) }
    }
    comments = CommentList.filter(comments, by: options.filter)
    var seen = Set<Int>()
    var result: [Int] = []
    for comment in comments where seen.insert(comment.pageIndex).inserted {
      result.append(comment.pageIndex)
    }
    return result
  }

  func reviewCommentSubtypeNames() -> [String] {
    guard let graph = editSession.currentGraph else { return [] }
    let comments = CommentList.comments(in: graph, pageIDs: editSession.pageIDs)
    var seen = Set<String>()
    var result: [String] = []
    for comment in comments {
      let name = Self.pdfNameText(comment.subtype ?? PDFName("Annot"))
      if seen.insert(name).inserted { result.append(name) }
    }
    return result.sorted()
  }

  func reviewCommentStateNames() -> [String] {
    guard let graph = editSession.currentGraph else { return [] }
    let comments = CommentList.comments(in: graph, pageIDs: editSession.pageIDs)
    var seen = Set<String>()
    var result: [String] = []
    for comment in comments {
      let name = Self.pdfNameText(comment.reviewState)
      if seen.insert(name).inserted { result.append(name) }
    }
    return result.sorted()
  }

  func reviewSummaryCounts(filter: CommentFilter, pageIndices: Set<Int>?) -> (total: Int, matched: Int) {
    guard let graph = editSession.currentGraph else { return (0, 0) }
    var comments = CommentList.comments(in: graph, pageIDs: editSession.pageIDs)
    let total = comments.count
    if let pageIndices { comments = comments.filter { pageIndices.contains($0.pageIndex) } }
    return (total, CommentList.filter(comments, by: filter).count)
  }

  // MARK: Comparison report

  /// Tools -> Export Comparison Report (PDF)... (direct menu route; requires an
  /// open comparison session).
  func exportComparisonReportPDF() {
    presentComparisonReportExport(
      options: ComparisonReportOptions(
        leftLabel: comparisonSession?.leftDocument.documentURL?.lastPathComponent
          ?? "Left document",
        rightLabel: comparisonSession?.rightDocument.documentURL?.lastPathComponent
          ?? "Right document",
        generatedOn: Self.reviewReportTimestamp()))
  }

  func presentComparisonReportExport(
    options: ComparisonReportOptions,
    includePageImages: Bool = true,
    includeRegionImages: Bool = true,
    completion: ((String?, Error?) -> Void)? = nil
  ) {
    guard comparisonSession != nil else {
      NSSound.beep()
      return
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    let base = (fileURL?.deletingPathExtension().lastPathComponent ?? "document")
      + "-comparison-report.pdf"
    panel.nameFieldStringValue = base
    panel.begin { [weak self] response in
      guard let self else { return }
      guard response == .OK, let url = panel.url else {
        completion?(nil, nil)
        return
      }
      do {
        var options = options
        if options.generatedOn == nil || options.generatedOn?.isEmpty == true {
          options.generatedOn = Self.reviewReportTimestamp()
        }
        let report = try self.writeComparisonReportPDF(
          to: url, options: options, includePageImages: includePageImages,
          includeRegionImages: includeRegionImages)
        completion?(report.summary, nil)
        let alert = NSAlert()
        alert.messageText = "Comparison Report Exported"
        alert.informativeText = report.summary
        alert.addButton(withTitle: "OK")
        alert.runModal()
      } catch {
        completion?(nil, error)
        self.presentError(error)
      }
    }
  }

  @discardableResult
  func writeComparisonReportPDF(
    to url: URL, options: ComparisonReportOptions, includePageImages: Bool,
    includeRegionImages: Bool
  ) throws -> ComparisonReport {
    guard let session = comparisonSession else {
      throw PDFError(.unsupported, "Open a document comparison before exporting a comparison report")
    }
    let result = session.result
    var pairImages: [Int: ComparisonReportPairImages] = [:]
    if includePageImages {
      var renderedPairs = 0
      for (pairIndex, pair) in result.pageMapping.enumerated() {
        let hasChanges = result.changes.contains { change in
          (change.rightPageIndex != nil && change.rightPageIndex == pair.rightIndex)
            || (change.leftPageIndex != nil && change.leftPageIndex == pair.leftIndex)
        }
        guard options.includeUnchangedPairs || hasChanges else { continue }
        guard renderedPairs < 40 else { break }
        let left = pair.leftIndex.flatMap { index in
          try? ReviewReportRenderer.rasterImage(
            document: session.leftDocument, pageIndex: index)
        }
        let right = pair.rightIndex.flatMap { index in
          try? ReviewReportRenderer.rasterImage(
            document: session.rightDocument, pageIndex: index)
        }
        if left != nil || right != nil {
          pairImages[pairIndex] = ComparisonReportPairImages(left: left, right: right)
          renderedPairs += 1
        }
      }
    }
    var regionImages: [Int: ReportRasterImage] = [:]
    if includeRegionImages {
      var renderedRegions = 0
      for (changeIndex, change) in result.changes.enumerated() {
        guard renderedRegions < 40 else { break }
        let image: ReportRasterImage?
        if let bounds = change.rightBounds, let rightIndex = change.rightPageIndex {
          image = try? ReviewReportRenderer.regionImage(
            document: session.rightDocument, pageIndex: rightIndex, contentRect: bounds)
        } else if let bounds = change.leftBounds, let leftIndex = change.leftPageIndex {
          image = try? ReviewReportRenderer.regionImage(
            document: session.leftDocument, pageIndex: leftIndex, contentRect: bounds)
        } else {
          image = nil
        }
        if let image {
          regionImages[changeIndex] = image
          renderedRegions += 1
        }
      }
    }
    let request = ComparisonReportRequest(
      result: result, comparisonOptions: session.options, options: options,
      pairImages: pairImages, regionImages: regionImages)
    let report = try ComparisonReportBuilder.build(
      request, limits: SPDFDocumentResourcePolicy.parsingLimits)
    try report.data.write(to: url, options: .atomic)
    return report
  }

  // MARK: Helpers

  static func reviewReportTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: Date())
  }

  static func pdfNameText(_ name: PDFName) -> String {
    String(decoding: name.bytes, as: UTF8.self)
  }
}
