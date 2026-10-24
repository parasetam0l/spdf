import Foundation
import PDFCore

/// REV-01: move an existing comment to another page while retaining its
/// object identity, thread links, state and metadata. Geometry follows the
/// incoming XFDF entry and the generated appearance is regenerated through
/// the same style path used by the appearance editor.
public struct MoveCommentToPageCommand: PDFEditCommand, Equatable, Sendable {
  public let sourcePageID: PDFObjectID
  public let sourceIndex: Int
  public let destinationPageID: PDFObjectID
  public let entry: CommentExchangeEntry

  public init(
    sourcePageID: PDFObjectID, sourceIndex: Int, destinationPageID: PDFObjectID,
    entry: CommentExchangeEntry
  ) {
    self.sourcePageID = sourcePageID
    self.sourceIndex = sourceIndex
    self.destinationPageID = destinationPageID
    self.entry = entry
  }

  public var name: String { "Move Comment to Page" }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] {
    [sourcePageID, destinationPageID]
  }

  public func validate(in graph: PDFGraph) throws {
    guard sourcePageID != destinationPageID else {
      throw PDFError(.malformed, "The comment is already on that page")
    }
    try AnnotationSupport.validatePage(sourcePageID, in: graph)
    try AnnotationSupport.validatePage(destinationPageID, in: graph)
    let source = try AnnotationSupport.annotationEntry(
      in: graph, pageID: sourcePageID, index: sourceIndex)
    guard source.objectID != nil else {
      throw PDFError(.unsupported, "Direct comment dictionaries cannot move between pages")
    }
    guard let subtype = Annotation.subtype(of: source.dictionary),
      subtype == entry.subtype,
      SetAnnotationStyleCommand.supportedSubtypes.contains(subtype)
    else {
      throw PDFError(.unsupported, "This comment type cannot move between pages")
    }
    guard CommentExchange.valid(rect: entry.rect) else {
      throw PDFError(.malformed, "The moved comment has invalid geometry")
    }
    if let issue = CommentExchange.newEntryIssue(entry) {
      throw PDFError(.malformed, "The moved comment is invalid: \(issue)")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let source = try AnnotationSupport.annotationEntry(
      in: graph, pageID: sourcePageID, index: sourceIndex)
    guard let objectID = source.objectID else {
      throw PDFError(.unsupported, "Direct comment dictionaries cannot move between pages")
    }
    var dictionary = source.dictionary
    dictionary[PDFName("Rect")] = .array(entry.rect.map { .real($0) })
    dictionary[PDFName("P")] = .reference(destinationPageID)
    switch entry.subtype {
    case PDFName("Highlight"), PDFName("Underline"), PDFName("StrikeOut"),
      PDFName("Squiggly"):
      let quads = entry.quadPoints ?? CommentExchange.quadPoints(from: entry.rect)
      dictionary[PDFName("QuadPoints")] = .array(quads.map { .real($0) })
    case PDFName("Line"):
      guard let start = entry.lineStart, let end = entry.lineEnd else {
        throw PDFError(.malformed, "The moved line has no endpoints")
      }
      dictionary[PDFName("L")] = .array(
        [start[0], start[1], end[0], end[1]].map { .real($0) })
      dictionary[PDFName("LE")] = .array([
        .name(entry.startEnding ?? PDFName("None")),
        .name(entry.endEnding ?? PDFName("None")),
      ])
      if let width = entry.borderWidth {
        dictionary[PDFName("BS")] = .dictionary([
          PDFName("Type"): .name(PDFName("Border")), PDFName("W"): .real(width),
        ])
      }
    case PDFName("Ink"):
      guard let strokes = entry.inkStrokes else {
        throw PDFError(.malformed, "The moved ink comment has no strokes")
      }
      dictionary[PDFName("InkList")] = .array(
        strokes.map { .array($0.map { .real($0) }) })
      if let width = entry.borderWidth {
        dictionary[PDFName("BS")] = .dictionary([
          PDFName("Type"): .name(PDFName("Border")), PDFName("W"): .real(width),
        ])
      }
    case PDFName("Polygon"), PDFName("PolyLine"):
      guard let vertices = entry.vertices else {
        throw PDFError(.malformed, "The moved polygon has no vertices")
      }
      dictionary[PDFName("Vertices")] = .array(vertices.map { .real($0) })
    case PDFName("Stamp"):
      if let icon = entry.iconName {
        dictionary[PDFName("Name")] = .name(icon)
      }
    default:
      break
    }
    if let color = entry.color {
      dictionary[PDFName("C")] = .array(color.map { .real($0) })
    }
    if let opacity = entry.opacity {
      dictionary[PDFName("CA")] = .real(opacity)
    }
    graph.objects[objectID] = .dictionary(dictionary)

    let destinationCount = Self.annotationCount(pageID: destinationPageID, in: graph) ?? 0
    try AnnotationSupport.removeAnnotation(
      pageID: sourcePageID, index: sourceIndex, in: &graph)
    try AnnotationSupport.appendToAnnots(
      .reference(objectID), pageID: destinationPageID, in: &graph)

    // Regenerate the appearance from the new geometry through the canonical
    // style command. Its output is validated by the transaction engine.
    let color =
      Annotation.numbers(dictionary[PDFName("C")], count: 3)
      ?? [0, 0, 0]
    let opacity = Annotation.number(dictionary[PDFName("CA")]) ?? 1
    let style = SetAnnotationStyleCommand(
      pageID: destinationPageID, annotationIndex: destinationCount,
      color: color, opacity: opacity)
    return try style.apply(to: graph)
  }

  private static func annotationCount(pageID: PDFObjectID, in graph: PDFGraph) -> Int? {
    guard case .dictionary(let page)? = graph.objects[pageID] else { return nil }
    switch page[PDFName("Annots")] {
    case .array(let values)?:
      return values.count
    case .reference(let id)?:
      guard case .array(let values)? = graph.objects[id] else { return nil }
      return values.count
    default:
      return 0
    }
  }
}
