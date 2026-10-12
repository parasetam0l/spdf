import Foundation
import PDFCore

/// P22-022: burn annotation appearances into page content and remove the
/// annotations. This is an explicit derivative operation: the marks become
/// ordinary content, interactivity is gone, and the edit can be undone like
/// any other transaction. Annotations without a generated annotation-relative
/// appearance (links, foreign appearances with a /Matrix) are left untouched.
public struct FlattenAnnotationsCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID

  public init(pageID: PDFObjectID) {
    self.pageID = pageID
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Flatten Annotations" }

  /// Pages that carry at least one flattenable annotation.
  public static func flattenablePageIDs(
    in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) -> [PDFObjectID] {
    pageIDs.filter { pageID in
      guard let annotations = try? AnnotationInventory.annotations(in: graph, pageID: pageID)
      else { return false }
      return annotations.contains { appearanceReference(of: $0, in: graph) != nil }
    }
  }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    let annotations = try AnnotationInventory.annotations(in: graph, pageID: pageID)
    let flattenable = annotations.filter { Self.appearanceReference(of: $0, in: graph) != nil }
    guard !flattenable.isEmpty else {
      throw PDFError(.malformed, "Page has no annotations with generated appearances to flatten")
    }
    let next = (graph.objects.keys.map(\.number).max() ?? 0) + flattenable.count + 1
    guard next <= 100_000_000 else {
      throw PDFError(.limitExceeded, "No room remains for flattened content streams")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    var base = graph.objects.keys.map(\.number).max() ?? 0
    let annotations = try AnnotationInventory.annotations(in: graph, pageID: pageID)
    var existingNames = Self.existingXObjectNames(in: graph, pageID: pageID)
    var contentReferences: [PDFValue] = []
    var resourceEntries: [PDFName: PDFValue] = [:]
    var flattenedIndexes: [Int] = []
    var removedObjectIDs: [PDFObjectID] = []
    var counter = 1

    for annotation in annotations {
      guard let appearanceID = Self.appearanceReference(of: annotation, in: graph),
        case .stream(let appearance)? = graph.objects[appearanceID]
      else { continue }
      let rect = Annotation.numbers(annotation.dictionary[PDFName("Rect")], count: 4) ?? [0, 0, 0, 0]
      let bbox = Annotation.numbers(appearance.dictionary[PDFName("BBox")], count: 4) ?? [0, 0, 0, 0]
      let scaleX = bbox[2] - bbox[0] != 0 ? (rect[2] - rect[0]) / (bbox[2] - bbox[0]) : 1
      let scaleY = bbox[3] - bbox[1] != 0 ? (rect[3] - rect[1]) / (bbox[3] - bbox[1]) : 1
      let translateX = rect[0] - bbox[0] * scaleX
      let translateY = rect[1] - bbox[1] * scaleY

      var name = PDFName("FmFlatten\(counter)")
      while existingNames.contains(name) {
        counter += 1
        name = PDFName("FmFlatten\(counter)")
      }
      counter += 1
      existingNames.insert(name)
      resourceEntries[name] = .reference(appearanceID)

      base += 1
      let streamID = PDFObjectID(base)
      let content =
        "q\n\(AnnotationSupport.number(scaleX)) 0 0 \(AnnotationSupport.number(scaleY)) "
        + "\(AnnotationSupport.number(translateX)) \(AnnotationSupport.number(translateY)) cm\n"
        + "/\(String(decoding: name.bytes, as: UTF8.self)) Do\nQ\n"
      let bytes = Data(content.utf8)
      graph.objects[streamID] = .stream(
        PDFStream(
          dictionary: [PDFName("Length"): .integer(Int64(bytes.count))], bytes: bytes))
      contentReferences.append(.reference(streamID))
      flattenedIndexes.append(annotation.index)
      if let objectID = annotation.objectID { removedObjectIDs.append(objectID) }
    }

    try Self.appendContents(contentReferences, pageID: pageID, in: &graph)
    try Self.addXObjectResources(resourceEntries, pageID: pageID, in: &graph)
    // Remove the flattened annotations from the array, highest index first.
    for index in flattenedIndexes.sorted(by: >) {
      try AnnotationSupport.removeAnnotation(pageID: pageID, index: index, in: &graph)
    }
    // Drop the now-unreferenced annotation objects; their appearances are
    // referenced by the page resources and survive.
    for objectID in removedObjectIDs where !AnnotationSupport.isReferenced(objectID, in: graph) {
      graph.objects[objectID] = nil
    }
    let highest = graph.objects.keys.map(\.number).max() ?? 0
    AnnotationSupport.finish(&graph, highest: highest)
    return graph
  }

  /// The generated appearance stream of an annotation, when it is an indirect
  /// form with no /Matrix (annotation-relative BBox, our generated profile).
  static func appearanceReference(of annotation: Annotation, in graph: PDFGraph) -> PDFObjectID? {
    guard case .dictionary(let appearance)? = annotation.dictionary[PDFName("AP")],
      case .reference(let id)? = appearance[PDFName("N")],
      isFlattenableForm(id, in: graph)
    else { return nil }
    return id
  }

  /// A generated annotation-relative appearance form: Form subtype with no
  /// (or identity) /Matrix.
  static func isFlattenableForm(_ id: PDFObjectID, in graph: PDFGraph) -> Bool {
    guard case .stream(let stream)? = graph.objects[id],
      stream.dictionary[PDFName("Subtype")] == .name(PDFName("Form"))
    else { return false }
    if let matrix = stream.dictionary[PDFName("Matrix")],
      matrix != .array([
        .integer(1), .integer(0), .integer(0), .integer(1), .integer(0), .integer(0),
      ])
    {
      return false
    }
    return true
  }

  static func existingXObjectNames(in graph: PDFGraph, pageID: PDFObjectID) -> Set<PDFName> {
    guard case .dictionary(let page)? = graph.objects[pageID] else { return [] }
    var resources: [PDFName: PDFValue]?
    switch page[PDFName("Resources")] {
    case .dictionary(let dictionary)?:
      resources = dictionary
    case .reference(let id)?:
      if case .dictionary(let dictionary)? = graph.objects[id] { resources = dictionary }
    default:
      resources = nil
    }
    guard let resources, case .dictionary(let xobjects)? = resources[PDFName("XObject")] else {
      return []
    }
    return Set(xobjects.keys)
  }

  static func appendContents(
    _ references: [PDFValue], pageID: PDFObjectID, in graph: inout PDFGraph
  ) throws {
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    switch page[PDFName("Contents")] {
    case .reference(let id)?:
      page[PDFName("Contents")] = .array([.reference(id)] + references)
    case .array(var items)?:
      items.append(contentsOf: references)
      page[PDFName("Contents")] = .array(items)
    case nil, .null?:
      page[PDFName("Contents")] = .array(references)
    default:
      throw PDFError(.malformed, "Page content is malformed")
    }
    graph.objects[pageID] = .dictionary(page)
  }

  static func addXObjectResources(
    _ entries: [PDFName: PDFValue], pageID: PDFObjectID, in graph: inout PDFGraph
  ) throws {
    func merged(_ resources: [PDFName: PDFValue]) -> [PDFName: PDFValue] {
      var resources = resources
      var xobjects: [PDFName: PDFValue]
      if case .dictionary(let existing)? = resources[PDFName("XObject")] {
        xobjects = existing
      } else {
        xobjects = [:]
      }
      for (name, value) in entries { xobjects[name] = value }
      resources[PDFName("XObject")] = .dictionary(xobjects)
      return resources
    }
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    switch page[PDFName("Resources")] {
    case .dictionary(let resources)?:
      page[PDFName("Resources")] = .dictionary(merged(resources))
    case .reference(let id)?:
      guard case .dictionary(let resources)? = graph.objects[id] else {
        throw PDFError(.malformed, "Page resources are missing")
      }
      graph.objects[id] = .dictionary(merged(resources))
    case nil, .null?:
      page[PDFName("Resources")] = .dictionary([PDFName("XObject"): .dictionary(entries)])
    default:
      throw PDFError(.malformed, "Page resources are malformed")
    }
    graph.objects[pageID] = .dictionary(page)
  }
}
