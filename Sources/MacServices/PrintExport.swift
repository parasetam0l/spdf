import AppKit
import CoreGraphics
import Foundation
import PDFCore
import PDFEditing
import PDFKit

/// P34-021–P34-024: native print integration and print-to-PDF derivatives.
/// Printing is appearance-oriented: pages are drawn through CoreGraphics with
/// their page boxes and rotation, so structure tags, form controls, and
/// annotation interactivity are flattened away — callers must disclose that.
public struct PDFPrintOptions: Sendable, Equatable {
  /// Uniform paper size in points; nil uses the largest selected page box.
  public var paperSize: CGSize?
  /// Scale applied to page boxes before fitting (1 = actual size).
  public var scale: Double

  public init(paperSize: CGSize? = nil, scale: Double = 1) {
    self.paperSize = paperSize
    self.scale = scale
  }
}

@MainActor
public enum PDFPrintExport {
  struct PageSet {
    let document: CGPDFDocument
    let pages: [CGPDFPage]
    let paperSize: CGSize
    let scale: Double
  }

  static func pageSet(
    pageIDs: [PDFObjectID], in graph: PDFGraph, options: PDFPrintOptions
  ) throws -> PageSet {
    let bytes = try PDFWriter.write(graph)
    guard let provider = CGDataProvider(data: bytes as CFData),
      let document = CGPDFDocument(provider)
    else { throw PageImageExport.ExportError.cannotOpenDocument }
    let allPageIDs = try PDFPageTree.pageIDs(in: graph)
    let indices = pageIDs.compactMap { pageID in allPageIDs.firstIndex(of: pageID).map { $0 + 1 } }
    let pages = indices.compactMap { document.page(at: $0) }
    var paper = options.paperSize ?? CGSize(width: 612, height: 792)
    if options.paperSize == nil {
      var width = 0.0
      var height = 0.0
      for page in pages {
        let box = PageImageExport.displayBox(of: page)
        width = max(width, box.width * options.scale)
        height = max(height, box.height * options.scale)
      }
      if width > 0, height > 0 { paper = CGSize(width: width, height: height) }
    }
    return PageSet(document: document, pages: pages, paperSize: paper, scale: options.scale)
  }

  /// A paginated view for `NSPrintOperation`: `knowsPageRange` covers the
  /// selected pages and `rectForPage` returns the uniform paper rect, so the
  /// print panel's page-range selection works on the selected pages.
  public static func pageView(
    pageIDs: [PDFObjectID], in graph: PDFGraph, options: PDFPrintOptions = .init()
  ) throws -> NSView {
    let set = try pageSet(pageIDs: pageIDs, in: graph, options: options)
    return PDFPrintPageView(
      document: set.document, pages: set.pages, paperSize: set.paperSize, scale: set.scale)
  }

  static func printInfo(paperSize: CGSize) -> NSPrintInfo {
    let printInfo = NSPrintInfo()
    printInfo.paperSize = paperSize
    printInfo.topMargin = 0
    printInfo.bottomMargin = 0
    printInfo.leftMargin = 0
    printInfo.rightMargin = 0
    printInfo.isHorizontallyCentered = true
    printInfo.isVerticallyCentered = true
    return printInfo
  }

  /// Write exactly the selected pages to a PDF through the native print
  /// pipeline (no dialog). Each page is rendered by its own print operation
  /// and the pages are merged with PDFKit, because a single `pdfOperation`
  /// captures one page of a view.
  @discardableResult
  public static func writePDF(
    pageIDs: [PDFObjectID], in graph: PDFGraph, to url: URL, options: PDFPrintOptions = .init()
  ) throws -> URL {
    let set = try pageSet(pageIDs: pageIDs, in: graph, options: options)
    let merged = PDFDocument()
    for page in set.pages {
      let view = PDFPrintPageView(
        document: set.document, pages: [page], paperSize: set.paperSize, scale: set.scale)
      let data = NSMutableData()
      let operation = NSPrintOperation.pdfOperation(with: view, inside: view.bounds, to: data)
      operation.printInfo = printInfo(paperSize: set.paperSize)
      operation.showsPrintPanel = false
      operation.showsProgressPanel = false
      guard operation.run() else {
        throw PDFError(.malformed, "The print pipeline did not produce a PDF")
      }
      guard let single = PDFDocument(data: data as Data), let page = single.page(at: 0) else {
        throw PDFError(.malformed, "The print pipeline produced an unreadable page")
      }
      merged.insert(page, at: merged.pageCount)
    }
    guard merged.pageCount > 0, merged.write(to: url) else {
      throw PDFError(.malformed, "The print pipeline produced no pages")
    }
    return url
  }

  /// Run the native print dialog for the whole document in a window.
  /// The optional operation hook exists for native acceptance tests: it
  /// observes the real NSPrintOperation before the system panel runs.
  public static func runPrintPanel(
    pageIDs: [PDFObjectID], in graph: PDFGraph, in window: NSWindow?,
    options: PDFPrintOptions = .init(),
    onOperation: ((NSPrintOperation) -> Void)? = nil
  ) throws {
    let view = try pageView(pageIDs: pageIDs, in: graph, options: options)
    let operation = NSPrintOperation(view: view, printInfo: printInfo(paperSize: view.frame.size))
    onOperation?(operation)
    if let window {
      operation.runModal(
        for: window, delegate: nil, didRun: nil, contextInfo: nil)
    } else {
      operation.run()
    }
  }
}

/// The paginated page view used by both the print panel and print-to-PDF.
@MainActor
final class PDFPrintPageView: NSView {
  private let document: CGPDFDocument
  fileprivate let pages: [CGPDFPage]
  private let scale: Double

  init(document: CGPDFDocument, pages: [CGPDFPage], paperSize: CGSize, scale: Double) {
    self.document = document
    self.pages = pages
    self.scale = scale
    super.init(frame: NSRect(origin: .zero, size: paperSize))
  }

  required init?(coder: NSCoder) { nil }

  override var isFlipped: Bool { false }

  override func knowsPageRange(_ range: NSRangePointer) -> Bool {
    range.pointee = NSRange(location: 1, length: max(pages.count, 1))
    return true
  }

  override func rectForPage(_ page: Int) -> NSRect {
    bounds
  }

  override func draw(_ dirtyRect: NSRect) {
    let context = NSGraphicsContext.current?.cgContext
    // NSPrintOperation.currentPage is zero-based.
    let index = NSPrintOperation.current?.currentPage ?? 0
    guard let context else { return }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(bounds)
    guard index >= 0, index < pages.count else { return }
    let page = pages[index]
    let box = PageImageExport.displayBox(of: page)
    let scaledWidth = box.width * scale
    let scaledHeight = box.height * scale
    guard scaledWidth > 0, scaledHeight > 0 else { return }
    let factor = min(bounds.width / scaledWidth, bounds.height / scaledHeight)
    let target = CGRect(
      x: bounds.origin.x + (bounds.width - scaledWidth * factor) / 2,
      y: bounds.origin.y + (bounds.height - scaledHeight * factor) / 2,
      width: scaledWidth * factor, height: scaledHeight * factor)
    context.saveGState()
    context.concatenate(
      page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
    context.drawPDFPage(page)
    context.restoreGState()
  }
}
