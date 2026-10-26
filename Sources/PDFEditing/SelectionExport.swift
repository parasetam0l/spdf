import Foundation
import PDFCore

/// EXP-06: selection/range export with an explicit appearance-versus-editability
/// choice. Only the requested scope is exported, reading order comes from the
/// owned layout engine, and Unicode text is retained (RTF uses RTF Unicode
/// escapes).
///
/// Boundary: editable exports reconstruct content from the owned layout/
/// reconstruction engine and explicitly list what is not carried (original
/// styling/geometry, links, annotations, scripts). Appearance exports are
/// rendered page/region images supplied through a renderer seam because
/// rendering lives in the platform layer; no active content is ever emitted.
public enum ExportScope: Sendable, Equatable {
  case document
  case pageRange(ClosedRange<Int>)
  case selection(CrossPageSelection)

  public var summary: String {
    switch self {
    case .document:
      return "whole document"
    case .pageRange(let range):
      return "pages \(range.lowerBound)-\(range.upperBound)"
    case .selection:
      return "current text selection"
    }
  }
}

public enum ExportFidelity: String, Codable, Sendable, Equatable, CaseIterable {
  case editable
  case appearance

  public var displayName: String {
    switch self {
    case .editable: return "Editable text"
    case .appearance: return "Appearance (rendered)"
    }
  }

  public var statement: String {
    switch self {
    case .editable:
      return "Editable export: text is reconstructed for editing; original styling, geometry and non-text objects are not preserved."
    case .appearance:
      return "Appearance export: content is rendered as an image so layout is preserved; the result is not editable text."
    }
  }
}

public enum SelectionExportFormat: String, Codable, Sendable, Equatable, CaseIterable {
  case text
  case html
  case rtf
  case docx
  case tableCSV

  public var displayName: String {
    switch self {
    case .text: return "Plain text"
    case .html: return "HTML"
    case .rtf: return "RTF"
    case .docx: return "DOCX"
    case .tableCSV: return "Tables (CSV)"
    }
  }

  public var fileExtension: String {
    switch self {
    case .text: return "txt"
    case .html: return "html"
    case .rtf: return "rtf"
    case .docx: return "docx"
    case .tableCSV: return "csv"
    }
  }

  public var supportsAppearance: Bool {
    switch self {
    case .html, .docx: return true
    default: return false
    }
  }

  public var declaredProfile: String {
    switch self {
    case .text:
      return "Plain text from the owned layout engine; encoding, line endings and page separators are explicit."
    case .html:
      return "Self-contained HTML (UTF-8) with escaped text, headings and tables; appearance mode embeds rendered PNG images. No scripts or active content."
    case .rtf:
      return "Minimal UTF-8 RTF 1.0 with Unicode escapes and paragraph breaks; styling beyond paragraph text is not carried."
    case .docx:
      return "Owned DOCX package; editable mode carries reconstructed paragraphs/headings/tables, appearance mode carries rendered page images."
    case .tableCSV:
      return "Owned table extraction to CSV (UTF-8/BOM/UTF-16, formula neutralization); only detected tables in scope are exported."
    }
  }
}

public struct SelectionExportOptions: Sendable, Equatable {
  public var textEncoding: PDFTextExportOptions.Encoding
  public var lineEnding: PDFTextExportOptions.LineEnding
  public var pageSeparator: PDFTextExportOptions.PageSeparator
  public var documentTitle: String?
  public var imageDPI: Double
  public var csvOptions: CSVExportOptions
  /// Explicit acknowledgement that appearance output is not editable; the
  /// caller must set it when choosing the appearance fidelity for HTML/DOCX.
  public var acknowledgeAppearanceIsRendered: Bool

  public init(
    textEncoding: PDFTextExportOptions.Encoding = .utf8,
    lineEnding: PDFTextExportOptions.LineEnding = .lf,
    pageSeparator: PDFTextExportOptions.PageSeparator = .blankLine,
    documentTitle: String? = nil, imageDPI: Double = 144,
    csvOptions: CSVExportOptions = CSVExportOptions(),
    acknowledgeAppearanceIsRendered: Bool = false
  ) {
    self.textEncoding = textEncoding
    self.lineEnding = lineEnding
    self.pageSeparator = pageSeparator
    self.documentTitle = documentTitle
    self.imageDPI = imageDPI
    self.csvOptions = csvOptions
    self.acknowledgeAppearanceIsRendered = acknowledgeAppearanceIsRendered
  }
}

/// One rendered appearance request. The region is in unrotated page content
/// space; nil means the whole page.
public struct AppearanceRenderRequest: Sendable, Equatable {
  public let graph: PDFGraph
  public let pageID: PDFObjectID
  public let pageIndex: Int
  public let region: [Double]?
  public let dpi: Double

  public init(
    graph: PDFGraph, pageID: PDFObjectID, pageIndex: Int, region: [Double]?, dpi: Double
  ) {
    self.graph = graph
    self.pageID = pageID
    self.pageIndex = pageIndex
    self.region = region
    self.dpi = dpi
  }
}

public struct AppearanceImage: Sendable, Equatable {
  public let pngData: Data
  public let pixelWidth: Int
  public let pixelHeight: Int

  public init(pngData: Data, pixelWidth: Int, pixelHeight: Int) {
    self.pngData = pngData
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
  }
}

/// Rendering seam supplied by the platform/app layer (MacServices renderer).
public struct AppearanceRenderer: Sendable {
  private let body: @Sendable (AppearanceRenderRequest) throws -> AppearanceImage

  public init(_ render: @escaping @Sendable (AppearanceRenderRequest) throws -> AppearanceImage) {
    self.body = render
  }

  public func render(_ request: AppearanceRenderRequest) throws -> AppearanceImage {
    try body(request)
  }
}

public struct SelectionExportPayload: Sendable, Equatable {
  public let format: SelectionExportFormat
  public let fidelity: ExportFidelity
  public let data: Data
  public let fileExtension: String
  public let scopeDescription: String
  public let limitations: [String]

  /// Every export states its fidelity losses up front.
  public var fidelityStatement: String {
    fidelity.statement + " " + limitations.joined(separator: " ")
  }
}

/// EXP-06: export one scope in one format with explicit fidelity.
public enum SelectionExport {
  public static let maximumSelectedPages = 512

  public static func export(
    format: SelectionExportFormat, scope: ExportScope,
    fidelity: ExportFidelity = .editable,
    options: SelectionExportOptions = SelectionExportOptions(),
    in graph: PDFGraph, pageIDs: [PDFObjectID],
    appearanceRenderer: AppearanceRenderer? = nil
  ) throws -> SelectionExportPayload {
    guard !pageIDs.isEmpty else {
      throw PDFError(.malformed, "The document has no pages")
    }
    guard pageIDs.count <= maximumSelectedPages else {
      throw PDFError(.limitExceeded, "The selection exceeds the page limit")
    }
    try validate(scope: scope, in: graph, pageIDs: pageIDs)
    if fidelity == .appearance {
      guard format.supportsAppearance else {
        throw PDFError(
          .unsupported,
          format.displayName + " carries editable text only; choose HTML or DOCX for an appearance export")
      }
      guard options.acknowledgeAppearanceIsRendered else {
        throw PDFError(
          .unsupported,
          "Appearance export needs an explicit acknowledgement that the result is a rendered image, not editable text")
      }
      guard let appearanceRenderer, let _ = appearanceRenderer as AppearanceRenderer? else {
        throw PDFError(.unsupported, "No appearance renderer is registered")
      }
    }
    let normalizedScope = scope
    let limitations = limitations(
      for: format, fidelity: fidelity, scope: normalizedScope)
    switch (format, fidelity) {
    case (.text, .editable):
      return try textPayload(
        scope: normalizedScope, options: options, graph: graph, pageIDs: pageIDs,
        limitations: limitations)
    case (.rtf, .editable):
      return try rtfPayload(
        scope: normalizedScope, options: options, graph: graph, pageIDs: pageIDs,
        limitations: limitations)
    case (.html, .editable):
      return try htmlEditablePayload(
        scope: normalizedScope, options: options, graph: graph, pageIDs: pageIDs,
        limitations: limitations)
    case (.html, .appearance):
      return try htmlAppearancePayload(
        scope: normalizedScope, options: options, graph: graph, pageIDs: pageIDs,
        renderer: appearanceRenderer!, limitations: limitations)
    case (.docx, .editable):
      return try docxEditablePayload(
        scope: normalizedScope, options: options, graph: graph, pageIDs: pageIDs,
        limitations: limitations)
    case (.docx, .appearance):
      return try docxAppearancePayload(
        scope: normalizedScope, options: options, graph: graph, pageIDs: pageIDs,
        renderer: appearanceRenderer!, limitations: limitations)
    case (.tableCSV, .editable):
      return try csvPayload(
        scope: normalizedScope, options: options, graph: graph, pageIDs: pageIDs,
        limitations: limitations)
    default:
      throw PDFError(
        .unsupported,
        format.displayName + " does not support " + fidelity.displayName.lowercased() + " export")
    }
  }

  // MARK: - Scope validation and resolution

  static func validate(scope: ExportScope, in graph: PDFGraph, pageIDs: [PDFObjectID]) throws {
    switch scope {
    case .document:
      return
    case .pageRange(let range):
      guard range.lowerBound >= 1, range.upperBound <= pageIDs.count,
        range.lowerBound <= range.upperBound
      else {
        throw PDFError(
          .malformed,
          "The page range must be within 1-\(pageIDs.count) and ordered")
      }
    case .selection(let selection):
      let counts = try pageIDs.map { try PageTextLayout.build(pageID: $0, in: graph).clusters.count }
      let ranges = selection.perPageRanges(clusterCounts: counts)
      let usable = ranges.filter { !$0.value.isEmpty }
      guard !usable.isEmpty else {
        throw PDFError(.malformed, "The text selection is empty")
      }
    }
  }

  /// 0-based page indices in order plus optional cluster range per page.
  static func resolve(
    scope: ExportScope, in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) throws -> (indices: [Int], ranges: [Int: Range<Int>]?) {
    switch scope {
    case .document:
      return (Array(pageIDs.indices), nil)
    case .pageRange(let range):
      let indices = Array((range.lowerBound - 1)...(range.upperBound - 1))
      return (indices, nil)
    case .selection(let selection):
      let counts = try pageIDs.map { try PageTextLayout.build(pageID: $0, in: graph).clusters.count }
      let ranges = selection.perPageRanges(clusterCounts: counts)
      let indices = ranges.keys.filter { !(ranges[$0] ?? 0..<0).isEmpty }.sorted()
      guard !indices.isEmpty else {
        throw PDFError(.malformed, "The text selection is empty")
      }
      return (indices, ranges)
    }
  }

  static func pageBounds(_ pageID: PDFObjectID, in graph: PDFGraph) -> [Double] {
    guard case .dictionary(let page)? = graph.objects[pageID],
      case .array(let box)? = page[PDFName("MediaBox")], box.count == 4
    else { return [0, 0, 612, 792] }
    let values = box.compactMap { value -> Double? in
      switch value {
      case .integer(let number): return Double(number)
      case .real(let number): return number
      default: return nil
      }
    }
    return values.count == 4 ? values : [0, 0, 612, 792]
  }

  /// Union of the selected clusters on one page (content space), or nil for a
  /// whole-page scope.
  static func selectionRegion(
    pageIndex: Int, ranges: [Int: Range<Int>]?, layout: PageTextLayout
  ) -> [Double]? {
    guard let ranges, let range = ranges[pageIndex], !range.isEmpty else { return nil }
    var minX = Double.greatestFiniteMagnitude
    var minY = Double.greatestFiniteMagnitude
    var maxX = -Double.greatestFiniteMagnitude
    var maxY = -Double.greatestFiniteMagnitude
    for index in range where layout.clusters.indices.contains(index) {
      let bounds = layout.clusters[index].bounds
      guard bounds.count == 4 else { continue }
      minX = min(minX, bounds[0])
      minY = min(minY, bounds[1])
      maxX = max(maxX, bounds[2])
      maxY = max(maxY, bounds[3])
    }
    guard minX <= maxX, minY <= maxY else { return nil }
    return [minX, minY, maxX, maxY]
  }

  static func limitations(
    for format: SelectionExportFormat, fidelity: ExportFidelity, scope: ExportScope
  ) -> [String] {
    var limitations: [String] = []
    if case .selection = scope {
      limitations.append(
        "Only the text within the current selection is exported; partial lines keep the selected characters only.")
    }
    switch format {
    case .text:
      limitations.append("Plain text carries no styling, tables, links or images.")
    case .html:
      limitations.append(
        "Editable HTML reconstructs paragraphs, headings and detected tables; original CSS, exact geometry, links, annotations and images are not carried.")
      if fidelity == .appearance {
        limitations.append(
          "Appearance HTML embeds rendered PNG images; text is not selectable or editable and no scripts are emitted.")
      }
    case .rtf:
      limitations.append(
        "RTF carries paragraph text with Unicode escapes only; run styling, colors, tables, links and images are not carried.")
    case .docx:
      limitations.append(
        DOCXExport.fidelityDisclosure)
      if fidelity == .appearance {
        limitations.append(
          "Appearance DOCX places rendered page images; the document is not editable text.")
      }
    case .tableCSV:
      limitations.append(
        "Only detected tables are exported; unruled or ambiguous tables may be missed and non-table text is not included.")
    }
    if fidelity == .appearance {
      limitations.append(ExportFidelity.appearance.statement)
    }
    return limitations
  }

  // MARK: - Editable payloads

  static func textPayload(
    scope: ExportScope, options: SelectionExportOptions, graph: PDFGraph,
    pageIDs: [PDFObjectID], limitations: [String]
  ) throws -> SelectionExportPayload {
    let resolved = try resolve(scope: scope, in: graph, pageIDs: pageIDs)
    let pageTextOptions = PDFTextExportOptions(
      lineEnding: options.lineEnding, encoding: .utf8,
      pageSeparator: options.pageSeparator)
    var parts: [String] = []
    if resolved.ranges == nil {
      let selectedPageIDs = resolved.indices.map { pageIDs[$0] }
      let data = try PDFTextExport.plainText(
        pageIDs: selectedPageIDs, in: graph, options: pageTextOptions)
      parts.append(String(decoding: data, as: UTF8.self))
    } else {
      for pageIndex in resolved.indices {
        let layout = try PageTextLayout.build(pageID: pageIDs[pageIndex], in: graph)
        let range = resolved.ranges?[pageIndex] ?? 0..<0
        let clusters = layout.clusters.enumerated()
          .filter { range.contains($0.offset) }
          .map(\.element)
        if !clusters.isEmpty {
          parts.append(PDFTextExport.text(of: clusters, options: pageTextOptions))
        }
      }
    }
    var text = parts.joined(separator: separator(for: options))
    text = applyLineEnding(text, ending: options.lineEnding)
    let data = encode(text, encoding: options.textEncoding)
    return SelectionExportPayload(
      format: .text, fidelity: .editable, data: data, fileExtension: "txt",
      scopeDescription: scope.summary, limitations: limitations)
  }

  static func rtfPayload(
    scope: ExportScope, options: SelectionExportOptions, graph: PDFGraph,
    pageIDs: [PDFObjectID], limitations: [String]
  ) throws -> SelectionExportPayload {
    let resolved = try resolve(scope: scope, in: graph, pageIDs: pageIDs)
    var body = ""
    for pageIndex in resolved.indices {
      let pageID = pageIDs[pageIndex]
      let candidates = try ParagraphReconstruction.candidates(pageID: pageID, in: graph)
      let filtered = candidates.filter { candidate in
        guard let ranges = resolved.ranges else { return true }
        let range = ranges[pageIndex] ?? 0..<0
        return candidate.clusterRange.overlaps(range)
      }
      for candidate in filtered {
        body += rtfEscape(candidate.text) + "\\par\n"
      }
    }
    let title = options.documentTitle ?? "sPDF export"
    let rtf =
      "{\\rtf1\\ansi\\deff0\n"
      + "{\\fonttbl{\\f0 Helvetica;}}\n"
      + "{\\info{\\title " + rtfEscape(title) + "}}\n"
      + "\\f0\\fs24\n" + body + "}\n"
    return SelectionExportPayload(
      format: .rtf, fidelity: .editable, data: Data(rtf.utf8),
      fileExtension: "rtf", scopeDescription: scope.summary, limitations: limitations)
  }

  static func htmlEditablePayload(
    scope: ExportScope, options: SelectionExportOptions, graph: PDFGraph,
    pageIDs: [PDFObjectID], limitations: [String]
  ) throws -> SelectionExportPayload {
    let resolved = try resolve(scope: scope, in: graph, pageIDs: pageIDs)
    let title = options.documentTitle ?? "sPDF export"
    var body = ""
    for pageIndex in resolved.indices {
      let pageID = pageIDs[pageIndex]
      body += "<section class=\"page\" id=\"page-\(pageIndex + 1)\">\n"
      let candidates = try ParagraphReconstruction.candidates(pageID: pageID, in: graph)
      let filtered = candidates.filter { candidate in
        guard let ranges = resolved.ranges else { return true }
        let range = ranges[pageIndex] ?? 0..<0
        return candidate.clusterRange.overlaps(range)
      }
      for candidate in filtered {
        let text = htmlEscape(candidate.text)
        if text.isEmpty { continue }
        switch candidate.kind {
        case .heading:
          body += "<h2>" + text + "</h2>\n"
        default:
          body += "<p>" + text + "</p>\n"
        }
      }
      let pageTables = try TableExtraction.tables(pageIDs: [pageID], in: graph)
      let selectionBounds = selectionRegion(
        pageIndex: pageIndex, ranges: resolved.ranges,
        layout: try PageTextLayout.build(pageID: pageID, in: graph))
      for table in pageTables where tableInScope(table, bounds: selectionBounds) {
        body += renderTableHTML(table).joined(separator: "\n") + "\n"
      }
      body += "</section>\n"
    }
    let html =
      "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
      + "<title>" + htmlEscape(title) + "</title>\n"
      + "<meta name=\"generator\" content=\"sPDF editable export\">\n</head>\n<body>\n"
      + body + "<footer><p>" + htmlEscape(limitations.joined(separator: " ")) + "</p></footer>\n"
      + "</body>\n</html>\n"
    return SelectionExportPayload(
      format: .html, fidelity: .editable, data: Data(html.utf8),
      fileExtension: "html", scopeDescription: scope.summary, limitations: limitations)
  }

  static func docxEditablePayload(
    scope: ExportScope, options: SelectionExportOptions, graph: PDFGraph,
    pageIDs: [PDFObjectID], limitations: [String]
  ) throws -> SelectionExportPayload {
    let resolved = try resolve(scope: scope, in: graph, pageIDs: pageIDs)
    let data: Data
    var mergedLimitations = limitations
    if resolved.ranges == nil {
      let selectedPageIDs = resolved.indices.map { pageIDs[$0] }
      let reconstruction = try DOCXReconstructionBuilder.reconstruct(
        pageIDs: selectedPageIDs, in: graph)
      mergedLimitations.append(contentsOf: reconstruction.limitations)
      data = try DOCXExport.package(
        reconstruction: reconstruction,
        options: DOCXExportOptions(
          mode: .editable, title: options.documentTitle))
    } else {
      var paragraphs: [DOCXParagraphInput] = []
      for pageIndex in resolved.indices {
        let pageID = pageIDs[pageIndex]
        let candidates = try ParagraphReconstruction.candidates(pageID: pageID, in: graph)
        let filtered = candidates.filter { candidate in
          let range = resolved.ranges?[pageIndex] ?? 0..<0
          return candidate.clusterRange.overlaps(range)
        }
        for candidate in filtered where !candidate.text.isEmpty {
          switch candidate.kind {
          case .heading:
            paragraphs.append(DOCXParagraphInput(text: candidate.text, style: .heading(level: 2)))
          default:
            paragraphs.append(DOCXParagraphInput(text: candidate.text))
          }
        }
      }
      guard !paragraphs.isEmpty else {
        throw PDFError(.malformed, "The selection contains no exportable text")
      }
      data = try DOCXExport.package(
        paragraphs: paragraphs,
        options: DOCXExportOptions(mode: .editable, title: options.documentTitle))
      mergedLimitations.append(
        "Selection DOCX uses the paragraph reconstruction profile: tables, images, links and original layout are not carried.")
    }
    return SelectionExportPayload(
      format: .docx, fidelity: .editable, data: data, fileExtension: "docx",
      scopeDescription: scope.summary, limitations: mergedLimitations)
  }

  static func csvPayload(
    scope: ExportScope, options: SelectionExportOptions, graph: PDFGraph,
    pageIDs: [PDFObjectID], limitations: [String]
  ) throws -> SelectionExportPayload {
    let resolved = try resolve(scope: scope, in: graph, pageIDs: pageIDs)
    var mergedLimitations = limitations
    var tables: [ExtractedTable] = []
    for pageIndex in resolved.indices {
      let pageID = pageIDs[pageIndex]
      let pageTables = try TableExtraction.tables(pageIDs: [pageID], in: graph)
      if resolved.ranges == nil {
        tables.append(contentsOf: pageTables)
      } else {
        let layout = try PageTextLayout.build(pageID: pageID, in: graph)
        let bounds = selectionRegion(
          pageIndex: pageIndex, ranges: resolved.ranges, layout: layout)
        tables.append(contentsOf: pageTables.filter { tableInScope($0, bounds: bounds) })
      }
    }
    if tables.isEmpty {
      mergedLimitations.append("No tables were detected in the selected scope.")
    }
    var sections: [String] = []
    for table in tables {
      sections.append(
        "# page " + String(table.pageIndex + 1) + ", table "
          + String(tables.firstIndex(of: table).map { $0 + 1 } ?? 1))
      sections.append(TableCSVExport.text(for: table, options: options.csvOptions))
    }
    let text = sections.joined(separator: options.csvOptions.lineEnding)
    let data = encode(text, encoding: textEncoding(for: options.csvOptions.encoding))
    return SelectionExportPayload(
      format: .tableCSV, fidelity: .editable, data: data, fileExtension: "csv",
      scopeDescription: scope.summary, limitations: mergedLimitations)
  }

  // MARK: - Appearance payloads

  static func htmlAppearancePayload(
    scope: ExportScope, options: SelectionExportOptions, graph: PDFGraph,
    pageIDs: [PDFObjectID], renderer: AppearanceRenderer, limitations: [String]
  ) throws -> SelectionExportPayload {
    let resolved = try resolve(scope: scope, in: graph, pageIDs: pageIDs)
    let title = options.documentTitle ?? "sPDF export"
    var images = ""
    for pageIndex in resolved.indices {
      let pageID = pageIDs[pageIndex]
      let layout = try PageTextLayout.build(pageID: pageID, in: graph)
      let region = selectionRegion(
        pageIndex: pageIndex, ranges: resolved.ranges, layout: layout)
      let image = try renderer.render(
        AppearanceRenderRequest(
          graph: graph, pageID: pageID, pageIndex: pageIndex, region: region,
          dpi: options.imageDPI))
      let base64 = image.pngData.base64EncodedString()
      images +=
        "<figure class=\"page\" id=\"page-\(pageIndex + 1)\">"
        + "<img alt=\"Page \(pageIndex + 1) appearance\" src=\"data:image/png;base64,"
        + base64 + "\">" + "</figure>\n"
    }
    let html =
      "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
      + "<title>" + htmlEscape(title) + "</title>\n</head>\n<body>\n"
      + images + "</body>\n</html>\n"
    return SelectionExportPayload(
      format: .html, fidelity: .appearance, data: Data(html.utf8),
      fileExtension: "html", scopeDescription: scope.summary, limitations: limitations)
  }

  static func docxAppearancePayload(
    scope: ExportScope, options: SelectionExportOptions, graph: PDFGraph,
    pageIDs: [PDFObjectID], renderer: AppearanceRenderer, limitations: [String]
  ) throws -> SelectionExportPayload {
    let resolved = try resolve(scope: scope, in: graph, pageIDs: pageIDs)
    var rendered: [String: AppearanceImage] = [:]
    var requests: [DOCXImageRequest] = []
    var blocks: [DOCXBlock] = []
    let firstBounds = pageBounds(pageIDs[resolved.indices.first ?? 0], in: graph)
    let pageWidth = firstBounds[2] - firstBounds[0]
    let pageHeight = firstBounds[3] - firstBounds[1]
    for (order, pageIndex) in resolved.indices.enumerated() {
      let pageID = pageIDs[pageIndex]
      let layout = try PageTextLayout.build(pageID: pageID, in: graph)
      let region = selectionRegion(
        pageIndex: pageIndex, ranges: resolved.ranges, layout: layout)
      let image = try renderer.render(
        AppearanceRenderRequest(
          graph: graph, pageID: pageID, pageIndex: pageIndex, region: region,
          dpi: options.imageDPI))
      let name = "page-" + String(order + 1) + ".png"
      rendered[name] = image
      let request = DOCXImageRequest(
        pageIndex: pageIndex, name: name,
        bounds: [0, 0, pageWidth, pageHeight], isAppearance: true, wrap: .inline)
      requests.append(request)
      blocks.append(DOCXBlock(kind: .image(request), runs: []))
    }
    let reconstruction = DOCXReconstruction(
      blocks: blocks, pageWidth: pageWidth, pageHeight: pageHeight,
      landscape: pageWidth > pageHeight,
      limitations: limitations, columns: 1)
    let renderedImages = rendered
    let resolver: DOCXImageResolver = { request in
      guard let image = renderedImages[request.name] else { return nil }
      return DOCXImageResource(
        data: image.pngData, fileExtension: "png", contentType: "image/png")
    }
    _ = requests
    let data = try DOCXExport.package(
      reconstruction: reconstruction,
      options: DOCXExportOptions(mode: .appearance, title: options.documentTitle),
      imageResolver: resolver)
    return SelectionExportPayload(
      format: .docx, fidelity: .appearance, data: data, fileExtension: "docx",
      scopeDescription: scope.summary, limitations: limitations)
  }

  // MARK: - Small helpers

  static func tableInScope(_ table: ExtractedTable, bounds: [Double]?) -> Bool {
    guard let bounds else { return true }
    guard table.bounds.count == 4 else { return false }
    return table.bounds[0] <= bounds[2] && table.bounds[2] >= bounds[0]
      && table.bounds[1] <= bounds[3] && table.bounds[3] >= bounds[1]
  }

  static func renderTableHTML(_ table: ExtractedTable) -> [String] {
    let grid = table.grid()
    var lines: [String] = ["<table>"]
    for row in grid {
      lines.append("<tr>")
      for value in row {
        let text = htmlEscape(value ?? "")
        lines.append(text.isEmpty ? "<td></td>" : "<td>" + text + "</td>")
      }
      lines.append("</tr>")
    }
    lines.append("</table>")
    return lines
  }

  static func separator(for options: SelectionExportOptions) -> String {
    switch options.pageSeparator {
    case .formFeed: return "\u{0C}"
    case .blankLine: return options.lineEnding == .crlf ? "\r\n\r\n" : "\n\n"
    case .none: return options.lineEnding == .crlf ? "\r\n" : "\n"
    }
  }

  static func applyLineEnding(_ text: String, ending: PDFTextExportOptions.LineEnding) -> String {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    switch ending {
    case .lf: return normalized
    case .crlf: return normalized.replacingOccurrences(of: "\n", with: "\r\n")
    }
  }

  static func encode(_ text: String, encoding: PDFTextExportOptions.Encoding) -> Data {
    switch encoding {
    case .utf8: return Data(text.utf8)
    case .utf16:
      var data = Data([0xFF, 0xFE])
      for unit in text.utf16 {
        data.append(UInt8(unit & 0xFF))
        data.append(UInt8((unit >> 8) & 0xFF))
      }
      return data
    }
  }

  static func textEncoding(for csv: CSVExportOptions.Encoding) -> PDFTextExportOptions.Encoding {
    switch csv {
    case .utf16: return .utf16
    default: return .utf8
    }
  }

  static func htmlEscape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }

  static func rtfEscape(_ text: String) -> String {
    var output = ""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\\": output += "\\\\"
      case "{": output += "\\{"
      case "}": output += "\\}"
      case "\n": output += "\\line "
      case "\r": break
      case "\t": output += "\\tab "
      default:
        if scalar.value >= 32, scalar.value < 127 {
          output.unicodeScalars.append(scalar)
        } else {
          output += "\\u" + String(Int(scalar.value)) + "?"
        }
      }
    }
    return output
  }
}
