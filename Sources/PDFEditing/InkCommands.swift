import Foundation
import PDFCore

/// P22-008: ink annotations from native pointer input. Strokes are flat point
/// lists in page space; the generated appearance strokes them with round caps
/// and joins.
public struct AddInkCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  /// One or more strokes; each stroke is a flat `x, y, x, y, …` list.
  public let strokes: [[Double]]
  public let color: [Double]
  public let borderWidth: Double
  public let opacity: Double
  public let contents: String?
  public let author: String?
  public let modified: String?
  public let subject: String?

  public init(
    pageID: PDFObjectID, strokes: [[Double]], color: [Double] = [0, 0, 0],
    borderWidth: Double = 2, opacity: Double = 1, contents: String? = nil, author: String? = nil,
    modified: String? = nil, subject: String? = nil
  ) {
    self.pageID = pageID
    self.strokes = strokes
    self.color = color
    self.borderWidth = borderWidth
    self.opacity = opacity
    self.contents = contents
    self.author = author
    self.modified = modified
    self.subject = subject
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Add Ink" }

  public static let maximumPoints = 20_000

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    guard !strokes.isEmpty else {
      throw PDFError(.malformed, "Ink needs at least one stroke")
    }
    var totalPoints = 0
    for stroke in strokes {
      guard stroke.count >= 4, stroke.count % 2 == 0, stroke.allSatisfy(\.isFinite) else {
        throw PDFError(.malformed, "Ink strokes need at least two finite points")
      }
      totalPoints += stroke.count / 2
    }
    guard totalPoints <= Self.maximumPoints else {
      throw PDFError(.limitExceeded, "Ink stroke exceeds the point limit")
    }
    try AnnotationSupport.validateColor(color, label: "Ink color")
    try AnnotationSupport.validateBorderWidth(borderWidth)
    guard borderWidth > 0 else {
      throw PDFError(.malformed, "Ink needs a visible stroke width")
    }
    try AnnotationSupport.validateOpacity(opacity)
    _ = try AnnotationSupport.allocate(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let allocation = try AnnotationSupport.allocate(in: graph)
    let rect = Self.rect(ofStrokes: strokes, borderWidth: borderWidth)
    var dictionary = AnnotationSupport.annotationDictionary(
      subtype: PDFName("Ink"), rect: rect, color: color, opacity: opacity,
      contents: contents, author: author, modified: modified, subject: subject,
      appearance: allocation.appearance)
    dictionary[PDFName("InkList")] = .array(
      strokes.map { stroke in .array(stroke.map { .real($0) }) })
    dictionary[PDFName("BS")] = .dictionary([
      PDFName("Type"): .name(PDFName("Border")),
      PDFName("W"): .real(borderWidth),
    ])
    graph.objects[allocation.annotation] = .dictionary(dictionary)
    graph.objects[allocation.appearance] = .stream(
      Self.appearance(
        strokes: strokes, rect: rect, color: color, borderWidth: borderWidth, opacity: opacity))
    try AnnotationSupport.appendToAnnots(
      .reference(allocation.annotation), pageID: pageID, in: &graph)
    AnnotationSupport.finish(&graph, allocation: allocation)
    return graph
  }

  /// Union of all stroke points padded by the stroke width so the appearance
  /// keeps round caps inside its box.
  static func rect(ofStrokes strokes: [[Double]], borderWidth: Double) -> [Double] {
    let rect = AnnotationSupport.rect(ofPoints: strokes.flatMap { $0 })
    let pad = borderWidth
    return [rect[0] - pad, rect[1] - pad, rect[2] + pad, rect[3] + pad]
  }

  static func appearance(
    strokes: [[Double]], rect: [Double], color: [Double], borderWidth: Double, opacity: Double
  ) -> PDFStream {
    var content = "q\n"
    content += "\(AnnotationSupport.number(color[0])) "
    content += "\(AnnotationSupport.number(color[1])) "
    content += "\(AnnotationSupport.number(color[2])) RG\n"
    content += "\(AnnotationSupport.number(borderWidth)) w\n1 J\n1 j\n"
    for stroke in strokes {
      content += "\(AnnotationSupport.number(stroke[0] - rect[0])) "
      content += "\(AnnotationSupport.number(stroke[1] - rect[1])) m\n"
      for index in stride(from: 2, to: stroke.count, by: 2) {
        content += "\(AnnotationSupport.number(stroke[index] - rect[0])) "
        content += "\(AnnotationSupport.number(stroke[index + 1] - rect[1])) l\n"
      }
      content += "S\n"
    }
    content += "Q\n"
    return AnnotationSupport.formAppearance(
      rect: rect, content: content,
      resources: AnnotationSupport.stateResources(opacity: opacity, blendMultiply: false))
  }
}
