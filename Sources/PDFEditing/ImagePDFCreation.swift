import Foundation
import PDFCore

/// PAG-08: create a new PDF with one page per raster image. The source pixels
/// are embedded once per page; no external application is involved.
public enum ImagePDFCreation {
  public enum PageLayout: String, Sendable, CaseIterable {
    case letter
    case a4
    case original

    public var title: String {
      switch self {
      case .letter: return "Letter"
      case .a4: return "A4"
      case .original: return "Original image size"
      }
    }
  }

  public struct Source: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let rgb8: Data
    public let alpha8: Data?

    public init(width: Int, height: Int, rgb8: Data, alpha8: Data? = nil) {
      self.width = width
      self.height = height
      self.rgb8 = rgb8
      self.alpha8 = alpha8
    }
  }

  /// Largest page dimension allowed by the PDF coordinate space. Original-size
  /// images beyond this are scaled proportionally.
  public static let maximumPageSide: Double = 14_400

  public static func make(
    sources: [Source], layout: PageLayout = .letter, limits: PDFLimits = PDFLimits()
  ) throws -> Data {
    guard !sources.isEmpty else {
      throw PDFError(.malformed, "Choose at least one image")
    }
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ])
    ]
    var pageIDs: [PDFObjectID] = []
    for (index, source) in sources.enumerated() {
      guard source.width >= 1, source.height >= 1,
        source.width <= 20_000, source.height <= 20_000,
        source.rgb8.count == source.width * source.height * 3
      else {
        throw PDFError(.malformed, "Image \(index + 1) has invalid pixel dimensions or samples")
      }
      let pageID = PDFObjectID(3 + index * 2)
      let contentID = PDFObjectID(pageID.number + 1)
      let size = pageSize(for: source, layout: layout)
      pageIDs.append(pageID)
      objects[pageID] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .real(size[0]), .real(size[1]),
        ]),
        PDFName("Contents"): .reference(contentID),
      ])
      objects[contentID] = .stream(
        PDFStream(
          dictionary: [PDFName("Length"): .integer(0)], bytes: Data()))
    }
    objects[PDFObjectID(2)] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(Int64(pageIDs.count)),
      PDFName("Kids"): .array(pageIDs.map(PDFValue.reference)),
    ])
    var graph = PDFGraph(
      objects: objects,
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    for (index, source) in sources.enumerated() {
      let size = pageSize(for: source, layout: layout)
      let rect = placementRect(for: source, page: size, layout: layout)
      graph = try PDFEditingEngine.commit(
        PDFTransaction([
          PlaceImageCommand(
            pageID: pageIDs[index], rect: rect,
            width: source.width, height: source.height,
            rgb8: source.rgb8, alpha8: source.alpha8)
        ]), to: graph, limits: limits)
    }
    return try PDFWriter.write(graph, limits: limits)
  }

  static func pageSize(for source: Source, layout: PageLayout) -> [Double] {
    switch layout {
    case .letter:
      return [612, 792]
    case .a4:
      return [595.276, 841.89]
    case .original:
      let width = max(1, Double(source.width))
      let height = max(1, Double(source.height))
      let scale = min(1, min(maximumPageSide / width, maximumPageSide / height))
      return [width * scale, height * scale]
    }
  }

  static func placementRect(for source: Source, page: [Double], layout: PageLayout) -> [Double] {
    let margin: Double = layout == .original ? 0 : 36
    let availableWidth = max(1, page[0] - margin * 2)
    let availableHeight = max(1, page[1] - margin * 2)
    let scale = min(
      availableWidth / Double(source.width),
      availableHeight / Double(source.height))
    let width = Double(source.width) * scale
    let height = Double(source.height) * scale
    let x = (page[0] - width) / 2
    let y = (page[1] - height) / 2
    return [x, y, x + width, y + height]
  }
}
