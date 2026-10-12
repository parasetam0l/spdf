import CoreGraphics
import Foundation
import PDFCore
import PDFEditing

/// P34-009–P34-013: HTML export with two explicit fidelity modes. Semantic
/// mode writes markup from the structure tree (or visual analysis when the
/// document is untagged) with escaped text, safe URI schemes, and an explicit
/// image policy; appearance mode renders pages to images so layout is
/// preserved. Neither mode emits scripts or active content.
public struct PDFHTMLExportOptions: Sendable, Equatable {
  public enum Mode: Sendable, Equatable {
    case semantic
    case appearance
  }

  public enum ImagePolicy: Sendable, Equatable {
    /// Self-contained HTML with `data:` images.
    case embed
    /// HTML plus a resources directory with relative paths.
    case package
  }

  public var mode: Mode
  public var imagePolicy: ImagePolicy
  public var imageDPI: Double
  public var documentTitle: String?
  public var packageDirectoryName: String

  public init(
    mode: Mode = .semantic, imagePolicy: ImagePolicy = .embed, imageDPI: Double = 144,
    documentTitle: String? = nil, packageDirectoryName: String = "images"
  ) {
    self.mode = mode
    self.imagePolicy = imagePolicy
    self.imageDPI = imageDPI
    self.documentTitle = documentTitle
    self.packageDirectoryName = packageDirectoryName
  }
}

public enum PDFHTMLExport {
  public struct Result: Sendable {
    public let html: String
    /// Relative path -> bytes for packaged resources (empty when embedding).
    public let resources: [String: Data]
  }

  public static func export(
    pageIDs: [PDFObjectID], in graph: PDFGraph, options: PDFHTMLExportOptions = .init()
  ) throws -> Result {
    switch options.mode {
    case .semantic:
      return try semantic(pageIDs: pageIDs, in: graph, options: options)
    case .appearance:
      return try appearance(pageIDs: pageIDs, in: graph, options: options)
    }
  }

  // MARK: - Semantic mode

  private static func semantic(
    pageIDs: [PDFObjectID], in graph: PDFGraph, options: PDFHTMLExportOptions
  ) throws -> Result {
    var resources: [String: Data] = [:]
    var figureCounter = 0
    let inventory = try PDFStructureInspector.inspect(in: graph, pageIDs: pageIDs)
    let links = PDFLinkInventory.links(in: graph, pageIDs: pageIDs)
    var linkByAnnotation: [PDFObjectID: PDFLinkTarget] = [:]
    for link in links {
      if let annotationID = link.annotationObjectID { linkByAnnotation[annotationID] = link }
    }

    var body = ""
    if inventory.isTagged, !inventory.elements.isEmpty {
      for element in inventory.elements {
        body += try render(
          element: element, depth: 0, pageIDs: pageIDs, graph: graph, options: options,
          linkByAnnotation: linkByAnnotation, figureCounter: &figureCounter,
          resources: &resources)
      }
    } else {
      for (pageIndex, pageID) in pageIDs.enumerated() {
        body += "<section class=\"page\" id=\"page-\(pageIndex + 1)\">\n"
        let suggestions = try StructureTaggingAssistant.analyze(pageIDs: [pageID], in: graph)
          .filter { $0.pageID == pageID }
        for suggestion in suggestions {
          switch suggestion.kind {
          case .heading(let level):
            let tag = "h\(min(max(level, 1), 6))"
            body += "<\(tag)>\(PDFHTMLEscape.escape(suggestion.snippet))</\(tag)>\n"
          case .paragraph:
            body += "<p>\(PDFHTMLEscape.escape(suggestion.snippet))</p>\n"
          case .figure:
            if let placement = suggestion.imageNames.first {
              body += try figureHTML(
                pageIndex: pageIndex, pageID: pageID, name: placement,
                bounds: suggestion.bounds, alt: nil, graph: graph, options: options,
                figureCounter: &figureCounter, resources: &resources)
            }
          case .artifact:
            break
          }
        }
        for link in links where link.pageIndex == pageIndex {
          body += linkHTML(link, text: nil) + "\n"
        }
        body += "</section>\n"
      }
    }

    let title = options.documentTitle ?? "Document"
    return Result(
      html: document(title: title, body: body), resources: resources)
  }

  private static func render(
    element: PDFStructureElement, depth: Int, pageIDs: [PDFObjectID], graph: PDFGraph,
    options: PDFHTMLExportOptions, linkByAnnotation: [PDFObjectID: PDFLinkTarget],
    figureCounter: inout Int, resources: inout [String: Data]
  ) throws -> String {
    guard depth < 24 else { return "" }
    let role = element.role
    let text = (try? PDFStructureText.text(of: element, pageIDs: pageIDs, in: graph)) ?? ""
    let escapedText = PDFHTMLEscape.escape(text)
    var nested = ""
    for child in element.children {
      if case .element(let nestedElement) = child {
        nested += try render(
          element: nestedElement, depth: depth + 1, pageIDs: pageIDs, graph: graph,
          options: options, linkByAnnotation: linkByAnnotation, figureCounter: &figureCounter,
          resources: &resources)
      }
    }

    func wrap(_ tag: String, attributes: String = "") -> String {
      let attributeText = attributes.isEmpty ? "" : " " + attributes
      return "<\(tag)\(attributeText)>\(escapedText)\(nested)</\(tag)>\n"
    }

    switch role {
    case "H1", "H2", "H3", "H4", "H5", "H6":
      return wrap(role.lowercased())
    case "H":
      return wrap("h1")
    case "P":
      return wrap("p")
    case "Span":
      return wrap("span")
    case "Quote", "BlockQuote":
      return wrap("blockquote")
    case "Code":
      return wrap("code")
    case "Note":
      return wrap("aside")
    case "Caption":
      return wrap("figcaption")
    case "L":
      return wrap("ul")
    case "LI":
      return wrap("li")
    case "LBody":
      return escapedText + nested
    case "Lbl":
      return wrap("span", attributes: "class=\"lbl\"")
    case "Table":
      return wrap("table")
    case "TR":
      return wrap("tr")
    case "TH":
      return wrap("th")
    case "TD":
      return wrap("td")
    case "THead":
      return wrap("thead")
    case "TBody":
      return wrap("tbody")
    case "TFoot":
      return wrap("tfoot")
    case "TOC":
      return wrap("nav")
    case "TOCI":
      return wrap("div", attributes: "class=\"toc-item\"")
    case "Index":
      return wrap("div", attributes: "class=\"index\"")
    case "BibEntry":
      return wrap("div", attributes: "class=\"bib-entry\"")
    case "Formula":
      return wrap("span", attributes: "class=\"formula\"")
    case "Form":
      // Forms export as inert text: never emit form controls or handlers.
      return wrap("span", attributes: "class=\"form\"")
    case "Reference":
      return wrap("span", attributes: "class=\"reference\"")
    case "Artifact":
      return ""
    case "Figure":
      var inner = ""
      let placements = (try? PDFStructureImages.placements(
        of: element, pageIDs: pageIDs, in: graph)) ?? []
      for placement in placements {
        inner += try figureHTML(
          pageIndex: placement.pageIndex, pageID: pageIDs[placement.pageIndex],
          name: placement.name, bounds: placement.bounds, alt: element.alt, graph: graph,
          options: options, figureCounter: &figureCounter, resources: &resources)
      }
      if placements.isEmpty, !text.isEmpty {
        inner += "<p>\(escapedText)</p>\n"
      }
      if let alt = element.alt {
        inner += "<figcaption>\(PDFHTMLEscape.escape(alt))</figcaption>\n"
      }
      guard !inner.isEmpty else { return "" }
      return "<figure>\n" + inner + "</figure>\n"
    case "Link":
      if let link = linkFor(element: element, linkByAnnotation: linkByAnnotation) {
        return linkHTML(link, text: text) + "\n"
      }
      return wrap("span", attributes: "class=\"link\"")
    default:
      return wrap("div")
    }
  }

  private static func linkFor(
    element: PDFStructureElement, linkByAnnotation: [PDFObjectID: PDFLinkTarget]
  ) -> PDFLinkTarget? {
    for child in element.children {
      if case .objectReference(let annotationID, _) = child,
        let link = linkByAnnotation[annotationID]
      {
        return link
      }
    }
    return nil
  }

  private static func linkHTML(_ link: PDFLinkTarget, text: String?) -> String {
    let label = PDFHTMLEscape.escape(text?.isEmpty == false ? text! : (link.uri ?? "Link"))
    if let uri = link.uri, let safe = PDFHTMLEscape.safeURI(uri) {
      return "<p class=\"link\"><a href=\"\(PDFHTMLEscape.escape(safe))\">\(label)</a></p>"
    }
    if let pageIndex = link.destinationPageIndex {
      return "<p class=\"link\"><a href=\"#page-\(pageIndex + 1)\">\(label)</a></p>"
    }
    // Unsafe or unresolved targets keep a neutral label without an href.
    let neutral = link.uri != nil ? "Link" : label
    return "<p class=\"link\">\(neutral)</p>"
  }

  private static func figureHTML(
    pageIndex: Int, pageID: PDFObjectID, name: String, bounds: [Double], alt: String?,
    graph: PDFGraph, options: PDFHTMLExportOptions, figureCounter: inout Int,
    resources: inout [String: Data]
  ) throws -> String {
    figureCounter += 1
    let data = try PageImageExport.regionImageData(
      pageID: pageID, in: graph, region: bounds,
      options: PageImageExportOptions(format: .png, dpi: options.imageDPI))
    let source: String
    switch options.imagePolicy {
    case .embed:
      source = "data:image/png;base64,\(data.base64EncodedString())"
    case .package:
      let fileName = String(format: "figure-%04d.png", figureCounter)
      let relative = "\(options.packageDirectoryName)/\(fileName)"
      resources[relative] = data
      source = relative
    }
    let altText = PDFHTMLEscape.escape(alt ?? name)
    return "<img src=\"\(source)\" alt=\"\(altText)\">\n"
  }

  // MARK: - Appearance mode

  private static func appearance(
    pageIDs: [PDFObjectID], in graph: PDFGraph, options: PDFHTMLExportOptions
  ) throws -> Result {
    var resources: [String: Data] = [:]
    var body = ""
    for (pageIndex, pageID) in pageIDs.enumerated() {
      let data = try PageImageExport.imageData(
        pageID: pageID, in: graph,
        options: PageImageExportOptions(format: .png, dpi: options.imageDPI))
      let source: String
      switch options.imagePolicy {
      case .embed:
        source = "data:image/png;base64,\(data.base64EncodedString())"
      case .package:
        let fileName = String(format: "page-%04d.png", pageIndex + 1)
        let relative = "\(options.packageDirectoryName)/\(fileName)"
        resources[relative] = data
        source = relative
      }
      body +=
        "<section class=\"page\" id=\"page-\(pageIndex + 1)\"><img class=\"page\" src=\"\(source)\" alt=\"Page \(pageIndex + 1)\"></section>\n"
    }
    return Result(
      html: document(title: options.documentTitle ?? "Document", body: body),
      resources: resources)
  }

  // MARK: - Document shell

  static func document(title: String, body: String) -> String {
    let style = """
      body { font-family: -apple-system, "Helvetica Neue", sans-serif; margin: 24px; }
      .page { margin: 0 0 24px 0; }
      img.page { max-width: 100%; height: auto; border: 1px solid #ddd; }
      figure { margin: 0 0 16px 0; }
      .lbl { font-weight: 600; margin-right: 4px; }
      .link { margin: 4px 0; }
      """
    return """
      <!DOCTYPE html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>\(PDFHTMLEscape.escape(title))</title>
      <style>
      \(style)
      </style>
      </head>
      <body>
      \(body)</body>
      </html>

      """
  }
}
