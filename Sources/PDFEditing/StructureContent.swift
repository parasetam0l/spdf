import Foundation
import PDFCore

/// P34-009/P34-010 support: the text of a structure element resolved through
/// its MCID children, in reading order. Bounded to the given pages.
public enum PDFStructureText {
  /// Text of one element's direct marked-content children.
  public static func text(
    of element: PDFStructureElement, pageIDs: [PDFObjectID], in graph: PDFGraph
  ) throws -> String {
    var pieces: [(pageIndex: Int, mcid: Int)] = []
    for child in element.children {
      if case .content(let pageIndex, let mcid) = child, let pageIndex {
        pieces.append((pageIndex, mcid))
      }
    }
    return try text(of: pieces, pageIDs: pageIDs, in: graph)
  }

  /// Text of explicit (page index, MCID) pieces; pieces on the same page are
  /// resolved through one layout pass.
  public static func text(
    of pieces: [(pageIndex: Int, mcid: Int)], pageIDs: [PDFObjectID], in graph: PDFGraph
  ) throws -> String {
    var layoutCache: [Int: PageTextLayout] = [:]
    var clusterCache: [Int: [[Int]]] = [:]
    var lines: [String] = []
    for piece in pieces {
      guard piece.pageIndex >= 0, piece.pageIndex < pageIDs.count else { continue }
      let pageID = pageIDs[piece.pageIndex]
      let clusters: [[Int]]
      if let cached = clusterCache[piece.pageIndex] {
        clusters = cached
      } else {
        clusters = try clusterIndices(for: pageID, in: graph)
        clusterCache[piece.pageIndex] = clusters
      }
      let layout: PageTextLayout
      if let cached = layoutCache[piece.pageIndex] {
        layout = cached
      } else {
        layout = try PageTextLayout.build(pageID: pageID, in: graph)
        layoutCache[piece.pageIndex] = layout
      }
      guard piece.mcid >= 0, piece.mcid < clusters.count else { continue }
      let range = clusters[piece.mcid]
      let selected = range.map { layout.clusters[$0] }
      let text = PDFTextExport.text(of: selected, options: PDFTextExportOptions(pageSeparator: .none))
      if !text.isEmpty { lines.append(text) }
    }
    return lines.joined(separator: "\n")
  }

  /// Cluster indices per MCID for one page (index = MCID, value = cluster
  /// indices in the page's reading order).
  static func clusterIndices(for pageID: PDFObjectID, in graph: PDFGraph) throws -> [[Int]] {
    let content = try PageContent.load(pageID: pageID, in: graph)
    let ranges = StructureTaggingAssistant.markedRanges(in: content)
    let runs = try TextRunIndexer.runs(in: content, graph: graph)
    let layout = try PageTextLayout.build(pageID: pageID, in: graph)
    var maxMCID = -1
    for range in ranges where range.mcid != nil {
      maxMCID = max(maxMCID, range.mcid ?? -1)
    }
    guard maxMCID >= 0 else { return [] }
    var result: [[Int]] = Array(repeating: [], count: maxMCID + 1)
    for range in ranges {
      guard let mcid = range.mcid, mcid >= 0, mcid <= maxMCID else { continue }
      var runIndices: Set<Int> = []
      for (index, run) in runs.enumerated()
      where range.instructions.contains(run.instructionIndex) {
        runIndices.insert(index)
      }
      guard !runIndices.isEmpty else { continue }
      var clusters: [Int] = []
      for (clusterIndex, cluster) in layout.clusters.enumerated()
      where runIndices.contains(cluster.runIndex) {
        clusters.append(clusterIndex)
      }
      result[mcid] = clusters
    }
    return result
  }
}

/// P34-011 support: image placements inside one element's marked content.
public struct PDFStructureImagePlacement: Sendable, Equatable {
  public let pageIndex: Int
  public let name: String
  public let bounds: [Double]

  public init(pageIndex: Int, name: String, bounds: [Double]) {
    self.pageIndex = pageIndex
    self.name = name
    self.bounds = bounds
  }
}

public enum PDFStructureImages {
  public static func placements(
    of element: PDFStructureElement, pageIDs: [PDFObjectID], in graph: PDFGraph
  ) throws -> [PDFStructureImagePlacement] {
    var result: [PDFStructureImagePlacement] = []
    for child in element.children {
      guard case .content(let pageIndex, let mcid) = child, let pageIndex,
        pageIndex >= 0, pageIndex < pageIDs.count
      else { continue }
      let content = try PageContent.load(pageID: pageIDs[pageIndex], in: graph)
      let ranges = StructureTaggingAssistant.markedRanges(in: content)
      guard let range = ranges.first(where: { $0.mcid == mcid }) else { continue }
      let placements = try StructureTaggingAssistant.imagePlacements(in: content, graph: graph)
      for placement in placements where range.instructions.contains(placement.instructionIndex) {
        result.append(
          PDFStructureImagePlacement(
            pageIndex: pageIndex, name: placement.name, bounds: placement.bounds))
      }
    }
    return result
  }
}

/// P34-010: link annotations with resolved URI or internal destinations.
public struct PDFLinkTarget: Sendable, Equatable {
  public let pageIndex: Int
  public let rect: [Double]
  public let uri: String?
  public let destinationPageIndex: Int?
  public let annotationObjectID: PDFObjectID?

  public init(
    pageIndex: Int, rect: [Double], uri: String?, destinationPageIndex: Int?,
    annotationObjectID: PDFObjectID?
  ) {
    self.pageIndex = pageIndex
    self.rect = rect
    self.uri = uri
    self.destinationPageIndex = destinationPageIndex
    self.annotationObjectID = annotationObjectID
  }
}

public enum PDFLinkInventory {
  public static func links(in graph: PDFGraph, pageIDs: [PDFObjectID]) -> [PDFLinkTarget] {
    var links: [PDFLinkTarget] = []
    for (pageIndex, pageID) in pageIDs.enumerated() {
      guard case .dictionary(let page)? = graph.objects[pageID],
        case .array(let annotations)? = page[PDFName("Annots")]
      else { continue }
      for value in annotations {
        guard case .reference(let annotationID) = value,
          case .dictionary(let annotation)? = graph.objects[annotationID],
          annotation[PDFName("Subtype")] == .name(PDFName("Link"))
        else { continue }
        let rect = numbers(annotation[PDFName("Rect")]) ?? []
        var uri: String?
        var destinationPage: Int?
        if case .dictionary(let action)? = resolved(annotation[PDFName("A")], in: graph) {
          if action[PDFName("S")] == .name(PDFName("URI")),
            case .string(let data)? = action[PDFName("URI")]
          {
            uri = AnnotationText.decode(data)
          } else if action[PDFName("S")] == .name(PDFName("GoTo")) {
            destinationPage = destinationPageIndex(
              of: action[PDFName("D")], graph: graph, pageIDs: pageIDs)
          }
        }
        if uri == nil, destinationPage == nil {
          destinationPage = destinationPageIndex(
            of: annotation[PDFName("Dest")], graph: graph, pageIDs: pageIDs)
        }
        guard uri != nil || destinationPage != nil else { continue }
        links.append(
          PDFLinkTarget(
            pageIndex: pageIndex, rect: rect, uri: uri, destinationPageIndex: destinationPage,
            annotationObjectID: annotationID))
      }
    }
    return links
  }

  /// Resolve a destination value (array, name, or string) to a page index.
  static func destinationPageIndex(
    of value: PDFValue?, graph: PDFGraph, pageIDs: [PDFObjectID]
  ) -> Int? {
    guard let value else { return nil }
    switch value {
    case .array(let values):
      guard let first = values.first, case .reference(let pageID) = first else { return nil }
      return pageIDs.firstIndex(of: pageID)
    case .name, .string:
      let key: String
      switch value {
      case .name(let name): key = String(decoding: name.bytes, as: UTF8.self)
      case .string(let data): key = AnnotationText.decode(data)
      default: return nil
      }
      if let destination = namedDestination(key, graph: graph) {
        return destinationPageIndex(of: destination, graph: graph, pageIDs: pageIDs)
      }
      return nil
    default:
      return nil
    }
  }

  static func namedDestination(_ name: String, graph: PDFGraph) -> PDFValue? {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID]
    else { return nil }
    if case .dictionary(let destinations)? = resolved(catalog[PDFName("Dests")], in: graph),
      let value = destinations[PDFName(name)]
    {
      return value
    }
    guard case .dictionary(let names)? = resolved(catalog[PDFName("Names")], in: graph),
      let tree = resolved(names[PDFName("Dests")], in: graph)
    else { return nil }
    return nameTreeLookup(name, in: tree, graph: graph, depth: 0)
  }

  private static func nameTreeLookup(
    _ name: String, in tree: PDFValue, graph: PDFGraph, depth: Int
  ) -> PDFValue? {
    guard depth < 32 else { return nil }
    guard case .dictionary(let dictionary) = tree else { return nil }
    if case .array(let numbers)? = dictionary[PDFName("Names")] {
      var index = 0
      while index + 1 < numbers.count {
        if case .string(let data) = numbers[index], AnnotationText.decode(data) == name {
          return numbers[index + 1]
        }
        index += 2
      }
    }
    if case .array(let kids)? = dictionary[PDFName("Kids")] {
      for kid in kids {
        if let found = nameTreeLookup(name, in: resolved(kid, in: graph) ?? kid, graph: graph, depth: depth + 1)
        {
          return found
        }
      }
    }
    return nil
  }

  static func resolved(_ value: PDFValue?, in graph: PDFGraph) -> PDFValue? {
    guard let value else { return nil }
    if case .reference(let id) = value { return graph.objects[id] }
    return value
  }

  static func numbers(_ value: PDFValue?) -> [Double]? {
    guard case .array(let values)? = value, values.count == 4 else { return nil }
    let numbers = values.compactMap { element -> Double? in
      switch element {
      case .integer(let number): return Double(number)
      case .real(let number): return number
      default: return nil
      }
    }
    return numbers.count == 4 ? numbers : nil
  }
}

/// P34-014: bookmarks (document outline) inventory and export.
public struct PDFOutlineItem: Sendable, Equatable {
  public let title: String
  public let pageIndex: Int?
  public let children: [PDFOutlineItem]

  public init(title: String, pageIndex: Int?, children: [PDFOutlineItem]) {
    self.title = title
    self.pageIndex = pageIndex
    self.children = children
  }
}

public enum PDFOutlineInventory {
  public static func items(in graph: PDFGraph, pageIDs: [PDFObjectID]) -> [PDFOutlineItem] {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID],
      case .reference(let outlinesID)? = catalog[PDFName("Outlines")],
      case .dictionary(let outlines)? = graph.objects[outlinesID],
      case .reference(let firstID)? = outlines[PDFName("First")]
    else { return [] }
    var visited: Set<PDFObjectID> = []
    var budget = 2_000
    func walk(_ id: PDFObjectID, depth: Int) -> [PDFOutlineItem] {
      guard depth < 32, budget > 0 else { return [] }
      var items: [PDFOutlineItem] = []
      var current: PDFObjectID? = id
      while let itemID = current, budget > 0, visited.insert(itemID).inserted {
        budget -= 1
        guard case .dictionary(let item)? = graph.objects[itemID] else { break }
        let title: String
        if case .string(let data)? = item[PDFName("Title")] {
          title = AnnotationText.decode(data)
        } else {
          title = ""
        }
        var destination: PDFValue?
        if case .dictionary(let action)? = PDFLinkInventory.resolved(item[PDFName("A")], in: graph),
          action[PDFName("S")] == .name(PDFName("GoTo"))
        {
          destination = action[PDFName("D")]
        } else {
          destination = item[PDFName("Dest")]
        }
        let pageIndex = PDFLinkInventory.destinationPageIndex(
          of: destination, graph: graph, pageIDs: pageIDs)
        var children: [PDFOutlineItem] = []
        if case .reference(let childID)? = item[PDFName("First")] {
          children = walk(childID, depth: depth + 1)
        }
        items.append(PDFOutlineItem(title: title, pageIndex: pageIndex, children: children))
        if case .reference(let nextID)? = item[PDFName("Next")] {
          current = nextID
        } else {
          current = nil
        }
      }
      return items
    }
    return walk(firstID, depth: 0)
  }
}

public enum PDFOutlineExport {
  public enum Format: Sendable, Equatable {
    case markdown
    case html
  }

  public static func text(
    items: [PDFOutlineItem], format: Format, documentTitle: String? = nil
  ) -> String {
    switch format {
    case .markdown:
      var lines: [String] = []
      if let documentTitle { lines.append("# \(documentTitle)") }
      for item in items { appendMarkdown(item, depth: 0, lines: &lines) }
      return lines.joined(separator: "\n")
    case .html:
      var html = "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n"
      html += "<title>\(escape(documentTitle ?? "Outline"))</title>\n</head>\n<body>\n"
      if let documentTitle { html += "<h1>\(escape(documentTitle))</h1>\n" }
      html += list(items)
      html += "\n</body>\n</html>\n"
      return html
    }
  }

  private static func appendMarkdown(
    _ item: PDFOutlineItem, depth: Int, lines: inout [String]
  ) {
    let indent = String(repeating: "  ", count: depth)
    if let pageIndex = item.pageIndex {
      lines.append("\(indent)- [\(item.title)](#page-\(pageIndex + 1))")
    } else {
      lines.append("\(indent)- \(item.title)")
    }
    for child in item.children { appendMarkdown(child, depth: depth + 1, lines: &lines) }
  }

  private static func list(_ items: [PDFOutlineItem]) -> String {
    guard !items.isEmpty else { return "" }
    var html = "<ul>\n"
    for item in items {
      let label: String
      if let pageIndex = item.pageIndex {
        label = "<a href=\"#page-\(pageIndex + 1)\">\(escape(item.title))</a>"
      } else {
        label = escape(item.title)
      }
      html += "<li>\(label)"
      if !item.children.isEmpty { html += "\n" + list(item.children) }
      html += "</li>\n"
    }
    html += "</ul>"
    return html
  }

  static func escape(_ text: String) -> String { PDFHTMLEscape.escape(text) }
}

/// P34-013/P34-027: HTML escaping used by every export that writes markup.
public enum PDFHTMLEscape {
  public static func escape(_ text: String) -> String {
    var result = ""
    for character in text {
      switch character {
      case "&": result += "&amp;"
      case "<": result += "&lt;"
      case ">": result += "&gt;"
      case "\"": result += "&quot;"
      case "'": result += "&#39;"
      default: result.append(character)
      }
    }
    return result
  }

  /// URI schemes ordinary exports may emit. Anything else (javascript:,
  /// data:, file:, …) is dropped rather than passed through.
  public static func safeURI(_ uri: String) -> String? {
    let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let colon = trimmed.firstIndex(of: ":") else { return nil }
    let scheme = trimmed[trimmed.startIndex..<colon].lowercased()
    guard ["http", "https", "mailto"].contains(scheme) else { return nil }
    return trimmed
  }
}
