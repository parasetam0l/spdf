import Foundation
import PDFCore

/// P22-002: add a highlight annotation whose quadrilaterals come from text
/// geometry. The command writes the full logical annotation dictionary plus a
/// generated appearance stream, so independent readers do not need to
/// synthesize one, and it appends to the page's /Annots array without
/// touching existing entries (P22-023).
public struct AddHighlightCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  /// QuadPoints in the conventional order per quadrilateral: upper-left,
  /// upper-right, lower-left, lower-right (8 numbers each).
  public let quads: [Double]
  public let color: [Double]
  public let opacity: Double
  public let contents: String?
  public let author: String?
  public let modified: String?
  public let subject: String?

  public init(
    pageID: PDFObjectID, quads: [Double], color: [Double] = [1, 0.84, 0], opacity: Double = 0.5,
    contents: String? = nil, author: String? = nil, modified: String? = nil,
    subject: String? = nil
  ) {
    self.pageID = pageID
    self.quads = quads
    self.color = color
    self.opacity = opacity
    self.contents = contents
    self.author = author
    self.modified = modified
    self.subject = subject
  }

  /// P16-017 bridge: axis-aligned cluster bounds (`[x0, y0, x1, y1]`) become
  /// quadrilaterals in the order Apple's PDFKit and common viewers use.
  public static func quads(forClusterBounds bounds: [[Double]]) -> [Double] {
    AnnotationSupport.quadPoints(fromClusterBounds: bounds)
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Add Highlight" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    try AnnotationSupport.validateQuads(quads)
    try AnnotationSupport.validateColor(color, label: "Highlight color")
    try AnnotationSupport.validateOpacity(opacity)
    _ = try AnnotationSupport.allocate(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let allocation = try AnnotationSupport.allocate(in: graph)
    let rect = AnnotationSupport.rect(ofQuads: quads)
    var dictionary = AnnotationSupport.annotationDictionary(
      subtype: PDFName("Highlight"), rect: rect, color: color, opacity: opacity,
      contents: contents, author: author, modified: modified, subject: subject,
      appearance: allocation.appearance)
    dictionary[PDFName("QuadPoints")] = .array(quads.map { .real($0) })
    graph.objects[allocation.annotation] = .dictionary(dictionary)
    graph.objects[allocation.appearance] = .stream(
      Self.appearance(quads: quads, rect: rect, color: color, opacity: opacity))
    try AnnotationSupport.appendToAnnots(
      .reference(allocation.annotation), pageID: pageID, in: &graph)
    AnnotationSupport.finish(&graph, allocation: allocation)
    return graph
  }

  /// Generated appearance in annotation-relative coordinates with a
  /// Multiply-blended, constant-alpha fill, mirroring what Apple's writer
  /// produces so no reader has to synthesize the highlight.
  static func appearance(
    quads: [Double], rect: [Double], color: [Double], opacity: Double
  ) -> PDFStream {
    var content = "q\n"
    content += "\(AnnotationSupport.number(color[0])) "
    content += "\(AnnotationSupport.number(color[1])) "
    content += "\(AnnotationSupport.number(color[2])) rg\n"
    content += "/GS0 gs\n"
    for index in stride(from: 0, to: quads.count, by: 8) {
      let points = (0..<4).map { pair in
        [quads[index + pair * 2] - rect[0], quads[index + pair * 2 + 1] - rect[1]]
      }
      // Cycle order: upper-left, upper-right, lower-right, lower-left.
      content += "\(AnnotationSupport.number(points[0][0])) "
      content += "\(AnnotationSupport.number(points[0][1])) m\n"
      content += "\(AnnotationSupport.number(points[1][0])) "
      content += "\(AnnotationSupport.number(points[1][1])) l\n"
      content += "\(AnnotationSupport.number(points[3][0])) "
      content += "\(AnnotationSupport.number(points[3][1])) l\n"
      content += "\(AnnotationSupport.number(points[2][0])) "
      content += "\(AnnotationSupport.number(points[2][1])) l\n"
      content += "h f\n"
    }
    content += "Q\n"
    return AnnotationSupport.formAppearance(
      rect: rect, content: content,
      resources: AnnotationSupport.stateResources(opacity: opacity, blendMultiply: true))
  }
}
