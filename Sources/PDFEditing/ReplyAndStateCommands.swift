import Foundation
import PDFCore

/// P22-014: threaded reply to an existing annotation. The reply is a text
/// note that carries an /IRT reference to its parent, so readers can rebuild
/// the comment thread, and deletion preflight can protect the relationship.
public struct AddReplyCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  /// Index of the parent annotation in the page's /Annots array.
  public let annotationIndex: Int
  public let text: String
  public let author: String?
  public let modified: String?
  public let color: [Double]
  public let size: Double

  public init(
    pageID: PDFObjectID, annotationIndex: Int, text: String, author: String? = nil,
    modified: String? = nil, color: [Double] = [1, 0.84, 0], size: Double = 20
  ) {
    self.pageID = pageID
    self.annotationIndex = annotationIndex
    self.text = text
    self.author = author
    self.modified = modified
    self.color = color
    self.size = size
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Add Reply" }

  public func validate(in graph: PDFGraph) throws {
    let parent = try AnnotationSupport.annotationEntry(
      in: graph, pageID: pageID, index: annotationIndex)
    guard parent.objectID != nil else {
      throw PDFError(.unsupported, "Replies need an indirect parent annotation")
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PDFError(.malformed, "A reply needs text")
    }
    try AnnotationSupport.validateColor(color, label: "Reply color")
    guard size.isFinite, size >= 8, size <= 72 else {
      throw PDFError(.malformed, "Reply size must be in 8...72")
    }
    _ = try AnnotationSupport.allocate(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let allocation = try AnnotationSupport.allocate(in: graph)
    let parent = try AnnotationSupport.annotationEntry(
      in: graph, pageID: pageID, index: annotationIndex)
    guard let parentObjectID = parent.objectID else {
      throw PDFError(.unsupported, "Replies need an indirect parent annotation")
    }
    let parentRect = Annotation.numbers(parent.dictionary[PDFName("Rect")], count: 4)
      ?? [0, 0, size, size]
    let rect = [
      parentRect[2] - size, parentRect[3] - size, parentRect[2], parentRect[3],
    ]
    var dictionary = AnnotationSupport.annotationDictionary(
      subtype: PDFName("Text"), rect: rect, color: color, opacity: nil,
      contents: text, author: author, modified: modified, subject: nil,
      appearance: allocation.appearance)
    dictionary[PDFName("Name")] = .name(PDFName("Comment"))
    dictionary[PDFName("Open")] = .boolean(false)
    dictionary[PDFName("IRT")] = .reference(parentObjectID)
    graph.objects[allocation.annotation] = .dictionary(dictionary)
    graph.objects[allocation.appearance] = .stream(
      AddNoteCommand.appearance(size: size, color: color))
    try AnnotationSupport.appendToAnnots(
      .reference(allocation.annotation), pageID: pageID, in: &graph)
    AnnotationSupport.finish(&graph, allocation: allocation)
    return graph
  }
}

/// P22-015: set or clear the review status of a markup annotation. Status is
/// stored as /State with the /Marked state model; clearing removes both keys.
public struct SetAnnotationStateCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let annotationIndex: Int
  /// nil or "None" clears the status.
  public let state: PDFName?

  public init(pageID: PDFObjectID, annotationIndex: Int, state: PDFName?) {
    self.pageID = pageID
    self.annotationIndex = annotationIndex
    self.state = state
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Set Review Status" }

  public static let supportedStates: [PDFName] = [
    PDFName("Accepted"), PDFName("Rejected"), PDFName("Completed"), PDFName("Cancelled"),
  ]

  public func validate(in graph: PDFGraph) throws {
    let entry = try AnnotationSupport.annotationEntry(
      in: graph, pageID: pageID, index: annotationIndex)
    if let state, state != PDFName("None") {
      guard Self.supportedStates.contains(state) else {
        throw PDFError(.unsupported, "Unsupported review status")
      }
    }
    if let subtype = Annotation.subtype(of: entry.dictionary) {
      guard subtype != PDFName("Link"), subtype != PDFName("Widget") else {
        throw PDFError(.unsupported, "Review status is not supported for this annotation type")
      }
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let entry = try AnnotationSupport.annotationEntry(
      in: graph, pageID: pageID, index: annotationIndex)
    var dictionary = entry.dictionary
    if let state, state != PDFName("None") {
      dictionary[PDFName("State")] = .name(state)
      dictionary[PDFName("StateModel")] = .name(PDFName("Marked"))
    } else {
      dictionary[PDFName("State")] = nil
      dictionary[PDFName("StateModel")] = nil
    }
    try AnnotationSupport.setAnnotation(dictionary, entry: entry, pageID: pageID, in: &graph)
    return graph
  }
}
