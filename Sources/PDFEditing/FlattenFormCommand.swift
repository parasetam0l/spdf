import Foundation
import PDFCore

/// P24-024: explicit form flattening. Widget appearances are burned into page
/// content, the widgets are removed from their pages, and the AcroForm field
/// tree is removed, so the form is no longer interactive. The operation is
/// undoable like any transaction, and page content outside the widgets is
/// untouched.
public struct FlattenFormCommand: PDFEditCommand, Equatable, Sendable {
  public init() {}

  public var name: String { "Flatten Form" }

  public func validate(in graph: PDFGraph) throws {
    let pageIDs = try PageTreeView(graph: graph).pages
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    let orphans = FormInventory.orphanedWidgets(in: graph, pageIDs: pageIDs)
    let flattenable =
      fields.contains { field in
        field.widgets.contains { widget in
          guard let objectID = widget.objectID,
            case .dictionary(let dictionary)? = graph.objects[objectID]
          else { return false }
          return Self.widgetAppearanceID(dictionary: dictionary, in: graph) != nil
        }
      }
      || orphans.contains { widget in
        guard let objectID = widget.objectID,
          case .dictionary(let dictionary)? = graph.objects[objectID]
        else { return false }
        return Self.widgetAppearanceID(dictionary: dictionary, in: graph) != nil
      }
    guard flattenable else {
      throw PDFError(.malformed, "No form widgets with appearances to flatten")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let pageIDs = try PageTreeView(graph: graph).pages
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    let fieldObjectIDs = fields.compactMap(\.fieldID)
    var widgetObjectIDs = fields.flatMap { $0.widgets.compactMap(\.objectID) }
    widgetObjectIDs.append(
      contentsOf: FormInventory.orphanedWidgets(in: graph, pageIDs: pageIDs)
        .compactMap(\.objectID))

    var base = graph.objects.keys.map(\.number).max() ?? 0
    for pageID in pageIDs {
      let annotations = try AnnotationInventory.annotations(in: graph, pageID: pageID)
      var existingNames = FlattenAnnotationsCommand.existingXObjectNames(
        in: graph, pageID: pageID)
      var contentReferences: [PDFValue] = []
      var resourceEntries: [PDFName: PDFValue] = [:]
      var flattenedIndexes: [Int] = []
      var counter = 1
      for annotation in annotations where annotation.subtype == PDFName("Widget") {
        guard let appearanceID = Self.widgetAppearanceID(
          dictionary: annotation.dictionary, in: graph),
          case .stream(let appearance)? = graph.objects[appearanceID]
        else { continue }
        let rect =
          Annotation.numbers(annotation.dictionary[PDFName("Rect")], count: 4) ?? [0, 0, 0, 0]
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
      }
      guard !contentReferences.isEmpty else { continue }
      try FlattenAnnotationsCommand.appendContents(contentReferences, pageID: pageID, in: &graph)
      try FlattenAnnotationsCommand.addXObjectResources(
        resourceEntries, pageID: pageID, in: &graph)
      for index in flattenedIndexes.sorted(by: >) {
        try AnnotationSupport.removeAnnotation(pageID: pageID, index: index, in: &graph)
      }
    }

    // Remove the AcroForm tree and the now-unreferenced field/widget objects;
    // their appearances stay because page resources reference them.
    if case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[rootID]
    {
      catalog[PDFName("AcroForm")] = nil
      graph.objects[rootID] = .dictionary(catalog)
    }
    for id in fieldObjectIDs + widgetObjectIDs
    where !AnnotationSupport.isReferenced(id, in: graph) {
      graph.objects[id] = nil
    }
    let highest = graph.objects.keys.map(\.number).max() ?? 0
    AnnotationSupport.finish(&graph, highest: highest)
    return graph
  }

  /// The appearance stream a widget currently shows (single stream or the /AS
  /// state stream), when it is a generated annotation-relative form.
  static func widgetAppearanceID(
    dictionary: [PDFName: PDFValue], in graph: PDFGraph
  ) -> PDFObjectID? {
    guard case .dictionary(let appearance)? = dictionary[PDFName("AP")] else { return nil }
    switch appearance[PDFName("N")] {
    case .reference(let id)?:
      return FlattenAnnotationsCommand.isFlattenableForm(id, in: graph) ? id : nil
    case .dictionary(let states)?:
      var current = PDFName("Off")
      if case .name(let name)? = dictionary[PDFName("AS")] { current = name }
      if case .reference(let id)? = states[current] ?? states[PDFName("Off")],
        FlattenAnnotationsCommand.isFlattenableForm(id, in: graph)
      {
        return id
      }
      return nil
    default:
      return nil
    }
  }
}
