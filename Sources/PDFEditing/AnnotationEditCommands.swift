import Foundation
import PDFCore

/// P22-011: move an existing annotation by rewriting its geometry. Generated
/// appearances are annotation-relative forms, so translating /Rect (and any
/// paired point lists) keeps them valid without touching other annotations or
/// their appearances (P22-019).
public struct MoveAnnotationCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let annotationIndex: Int
  public let dx: Double
  public let dy: Double

  public init(pageID: PDFObjectID, annotationIndex: Int, dx: Double, dy: Double) {
    self.pageID = pageID
    self.annotationIndex = annotationIndex
    self.dx = dx
    self.dy = dy
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Move Annotation" }

  public func validate(in graph: PDFGraph) throws {
    let entry = try AnnotationSupport.annotationEntry(
      in: graph, pageID: pageID, index: annotationIndex)
    guard dx.isFinite, dy.isFinite else {
      throw PDFError(.malformed, "Annotation offset is invalid")
    }
    guard Annotation.numbers(entry.dictionary[PDFName("Rect")], count: 4) != nil else {
      throw PDFError(.malformed, "Annotation has no rectangle to move")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let entry = try AnnotationSupport.annotationEntry(
      in: graph, pageID: pageID, index: annotationIndex)
    var dictionary = entry.dictionary
    AnnotationSupport.translate(&dictionary, dx: dx, dy: dy)
    try AnnotationSupport.setAnnotation(dictionary, entry: entry, pageID: pageID, in: &graph)
    return graph
  }
}

/// P22-011: resize an existing annotation by mapping its rectangle and every
/// paired point list from the old box to the new one. Appearances stay
/// byte-identical because readers map the form BBox onto the new /Rect.
public struct ResizeAnnotationCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let annotationIndex: Int
  public let rect: [Double]

  public init(pageID: PDFObjectID, annotationIndex: Int, rect: [Double]) {
    self.pageID = pageID
    self.annotationIndex = annotationIndex
    self.rect = rect
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Resize Annotation" }

  public func validate(in graph: PDFGraph) throws {
    let entry = try AnnotationSupport.annotationEntry(
      in: graph, pageID: pageID, index: annotationIndex)
    try AnnotationSupport.validateRect(rect)
    guard Annotation.numbers(entry.dictionary[PDFName("Rect")], count: 4) != nil else {
      throw PDFError(.malformed, "Annotation has no rectangle to resize")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let entry = try AnnotationSupport.annotationEntry(
      in: graph, pageID: pageID, index: annotationIndex)
    guard let old = Annotation.numbers(entry.dictionary[PDFName("Rect")], count: 4) else {
      throw PDFError(.malformed, "Annotation has no rectangle to resize")
    }
    var dictionary = entry.dictionary
    AnnotationSupport.rescale(&dictionary, from: old, to: rect)
    try AnnotationSupport.setAnnotation(dictionary, entry: entry, pageID: pageID, in: &graph)
    return graph
  }
}

/// P22-011: style editing for supported annotation types. Color and opacity
/// are rewritten and the generated appearance stream is regenerated in place
/// from the annotation's own geometry, so other annotations and their
/// appearances stay untouched (P22-019).
public struct SetAnnotationStyleCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let annotationIndex: Int
  public let color: [Double]?
  public let opacity: Double?

  public init(pageID: PDFObjectID, annotationIndex: Int, color: [Double]? = nil, opacity: Double? = nil) {
    self.pageID = pageID
    self.annotationIndex = annotationIndex
    self.color = color
    self.opacity = opacity
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Set Annotation Style" }

  static let supportedSubtypes: Set<PDFName> = [
    PDFName("Highlight"), PDFName("Underline"), PDFName("StrikeOut"), PDFName("Squiggly"),
    PDFName("Square"), PDFName("Circle"), PDFName("Line"), PDFName("Ink"),
    PDFName("Text"), PDFName("FreeText"), PDFName("Stamp"),
  ]

  public func validate(in graph: PDFGraph) throws {
    let entry = try AnnotationSupport.annotationEntry(
      in: graph, pageID: pageID, index: annotationIndex)
    guard color != nil || opacity != nil else {
      throw PDFError(.malformed, "Style editing needs a color or an opacity")
    }
    if let color { try AnnotationSupport.validateColor(color, label: "Style color") }
    if let opacity { try AnnotationSupport.validateOpacity(opacity) }
    guard let subtype = Self.subtype(of: entry.dictionary),
      Self.supportedSubtypes.contains(subtype)
    else {
      throw PDFError(.unsupported, "Style editing is not supported for this annotation type yet")
    }
    guard Self.appearanceID(of: entry.dictionary, in: graph) != nil else {
      throw PDFError(.unsupported, "Annotation has no generated appearance to update")
    }
    try Self.validateGeometry(subtype: subtype, dictionary: entry.dictionary)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let entry = try AnnotationSupport.annotationEntry(
      in: graph, pageID: pageID, index: annotationIndex)
    guard let subtype = Self.subtype(of: entry.dictionary),
      let appearanceID = Self.appearanceID(of: entry.dictionary, in: graph)
    else {
      throw PDFError(.unsupported, "Annotation has no generated appearance to update")
    }
    var dictionary = entry.dictionary
    let newColor =
      color ?? Annotation.numbers(dictionary[PDFName("C")], count: 3)
      ?? [0, 0, 0]
    let newOpacity = opacity ?? Annotation.number(dictionary[PDFName("CA")]) ?? 1
    let rect = Annotation.numbers(dictionary[PDFName("Rect")], count: 4) ?? [0, 0, 0, 0]

    let stream: PDFStream
    switch subtype {
    case PDFName("Highlight"):
      guard let quads = Self.quads(of: dictionary) else {
        throw PDFError(.malformed, "Highlight has no quadrilaterals")
      }
      stream = AddHighlightCommand.appearance(
        quads: quads, rect: rect, color: newColor, opacity: newOpacity)
    case PDFName("Underline"), PDFName("StrikeOut"):
      guard let quads = Self.quads(of: dictionary) else {
        throw PDFError(.malformed, "Text markup has no quadrilaterals")
      }
      let style: TextMarkupStyle = subtype == PDFName("Underline") ? .underline : .strikeout
      stream = AddTextMarkupCommand.appearance(
        style: style, quads: quads, rect: rect, color: newColor, opacity: newOpacity)
    case PDFName("Squiggly"):
      guard let quads = Self.quads(of: dictionary) else {
        throw PDFError(.malformed, "Squiggly markup has no quadrilaterals")
      }
      stream = ImportCommentsCommand.squigglyAppearance(
        quads: quads, rect: rect, color: newColor, opacity: newOpacity)
    case PDFName("Square"), PDFName("Circle"):
      let kind: ShapeKind = subtype == PDFName("Square") ? .square : .circle
      stream = AddShapeCommand.appearance(
        kind: kind, rect: rect, borderColor: newColor, fillColor: Self.fillColor(of: dictionary),
        borderWidth: AnnotationSupport.borderWidth(of: dictionary), opacity: newOpacity)
    case PDFName("Line"):
      guard let line = Self.linePoints(of: dictionary) else {
        throw PDFError(.malformed, "Line annotation has no endpoints")
      }
      let width = AnnotationSupport.borderWidth(of: dictionary)
      guard let endings = Self.lineEndings(of: dictionary) else {
        throw PDFError(.unsupported, "Unsupported line ending style")
      }
      let geometry = AddLineCommand.geometry(
        from: [line[0], line[1]], to: [line[2], line[3]], borderWidth: width,
        startEnding: endings.0, endEnding: endings.1)
      stream = AddLineCommand.appearance(
        from: [line[0], line[1]], to: [line[2], line[3]], rect: geometry.rect,
        startArrow: geometry.startArrow, endArrow: geometry.endArrow, color: newColor,
        borderWidth: width, opacity: newOpacity)
      dictionary[PDFName("Rect")] = .array(geometry.rect.map { .real($0) })
      dictionary[PDFName("IC")] = .array(newColor.map { .real($0) })
    case PDFName("Ink"):
      guard let strokes = Self.inkStrokes(of: dictionary) else {
        throw PDFError(.malformed, "Ink annotation has no strokes")
      }
      let width = AnnotationSupport.borderWidth(of: dictionary)
      stream = AddInkCommand.appearance(
        strokes: strokes, rect: rect, color: newColor,
        borderWidth: width > 0 ? width : 2, opacity: newOpacity)
    case PDFName("Text"):
      let size = min(max(min(rect[2] - rect[0], rect[3] - rect[1]), 8), 72)
      stream = AddNoteCommand.appearance(size: size, color: newColor, opacity: newOpacity)
    case PDFName("FreeText"):
      let fontID = try Self.ensureHelveticaFont(in: &graph, dictionary: &dictionary)
      let text = Self.text(dictionary[PDFName("Contents")]) ?? ""
      let appearance = Self.text(dictionary[PDFName("DA")])
      let fontSize = CommentExchange.freeTextFontSize(appearance)
      stream = AddFreeTextCommand.appearance(
        rect: rect, text: text, fontSize: fontSize, textColor: newColor,
        fillColor: nil, borderColor: nil, borderWidth: 0, fontID: fontID,
        opacity: newOpacity)
      dictionary[PDFName("DA")] = .string(
        Data(
          AnnotationSupport.defaultAppearanceString(
            fontSize: fontSize, color: newColor).utf8))
      dictionary[PDFName("DR")] = .dictionary([
        PDFName("Font"): .dictionary([PDFName("Helvetica"): .reference(fontID)])
      ])
    case PDFName("Stamp"):
      let fontID = try Self.ensureHelveticaFont(in: &graph, dictionary: &dictionary)
      var label = "Stamp"
      if case .name(let stampName)? = dictionary[PDFName("Name")] {
        let raw = String(decoding: stampName.bytes, as: UTF8.self)
        label =
          StampName.allCases.first(where: { $0.pdfName == stampName })?.label
          ?? (raw.isEmpty ? "Stamp" : raw)
      }
      let width = AnnotationSupport.borderWidth(of: dictionary)
      stream = AddStampCommand.appearance(
        rect: rect, label: label, color: newColor,
        borderWidth: width > 0 ? width : 2, fontID: fontID, opacity: newOpacity)
    default:
      throw PDFError(.unsupported, "Style editing is not supported for this annotation type yet")
    }
    dictionary[PDFName("C")] = .array(newColor.map { .real($0) })
    dictionary[PDFName("CA")] = .real(newOpacity)
    graph.objects[appearanceID] = .stream(stream)
    try AnnotationSupport.setAnnotation(dictionary, entry: entry, pageID: pageID, in: &graph)
    return graph
  }

  static func subtype(of dictionary: [PDFName: PDFValue]) -> PDFName? {
    Annotation.subtype(of: dictionary)
  }

  static func appearanceID(of dictionary: [PDFName: PDFValue], in graph: PDFGraph) -> PDFObjectID? {
    guard case .dictionary(let appearance)? = dictionary[PDFName("AP")],
      case .reference(let appearanceID)? = appearance[PDFName("N")],
      case .stream? = graph.objects[appearanceID]
    else { return nil }
    return appearanceID
  }

  static func quads(of dictionary: [PDFName: PDFValue]) -> [Double]? {
    guard case .array(let values)? = dictionary[PDFName("QuadPoints")], !values.isEmpty,
      values.count % 8 == 0
    else { return nil }
    let numbers = values.compactMap(Annotation.number)
    return numbers.count == values.count ? numbers : nil
  }

  static func fillColor(of dictionary: [PDFName: PDFValue]) -> [Double]? {
    guard case .array(let values)? = dictionary[PDFName("IC")] else { return nil }
    let numbers = values.compactMap(Annotation.number)
    guard numbers.count == values.count else { return nil }
    switch numbers.count {
    case 1: return [numbers[0], numbers[0], numbers[0]]
    case 3: return numbers
    default: return nil
    }
  }

  static func linePoints(of dictionary: [PDFName: PDFValue]) -> [Double]? {
    guard case .array(let values)? = dictionary[PDFName("L")], values.count == 4 else {
      return nil
    }
    let numbers = values.compactMap(Annotation.number)
    return numbers.count == 4 ? numbers : nil
  }

  static func inkStrokes(of dictionary: [PDFName: PDFValue]) -> [[Double]]? {
    guard case .array(let strokes)? = dictionary[PDFName("InkList")] else { return nil }
    var result: [[Double]] = []
    for stroke in strokes {
      guard case .array(let values) = stroke else { return nil }
      let numbers = values.compactMap(Annotation.number)
      guard numbers.count == values.count, numbers.count >= 4, numbers.count % 2 == 0 else {
        return nil
      }
      result.append(numbers)
    }
    return result.isEmpty ? nil : result
  }

  static func text(_ value: PDFValue?) -> String? {
    guard case .string(let data)? = value else { return nil }
    return AnnotationText.decode(data)
  }

  static func ensureHelveticaFont(
    in graph: inout PDFGraph, dictionary: inout [PDFName: PDFValue]
  ) throws -> PDFObjectID {
    if case .dictionary(let resources)? = dictionary[PDFName("DR")],
      case .dictionary(let fonts)? = resources[PDFName("Font")],
      case .reference(let id)? = fonts[PDFName("Helvetica")],
      graph.objects[id] != nil
    {
      return id
    }
    if let existing = AnnotationSupport.helveticaFontID(in: graph) { return existing }
    let id = try AnnotationSupport.allocateOne(in: graph)
    graph.objects[id] = .dictionary(AnnotationSupport.helveticaFontDictionary())
    graph.trailer[PDFName("Size")] = .integer(Int64(id.number + 1))
    return id
  }

  static func lineEndings(of dictionary: [PDFName: PDFValue]) -> (LineEnding, LineEnding)? {
    guard case .array(let values)? = dictionary[PDFName("LE")] else { return (.none, .none) }
    guard values.count == 2 else { return nil }
    func ending(_ value: PDFValue) -> LineEnding? {
      guard case .name(let name) = value else { return nil }
      switch name {
      case PDFName("None"): return LineEnding.none
      case PDFName("ClosedArrow"): return LineEnding.closedArrow
      default: return nil
      }
    }
    guard let start = ending(values[0]), let end = ending(values[1]) else { return nil }
    return (start, end)
  }

  static func validateGeometry(subtype: PDFName, dictionary: [PDFName: PDFValue]) throws {
    switch subtype {
    case PDFName("Highlight"), PDFName("Underline"), PDFName("StrikeOut"),
      PDFName("Squiggly"):
      guard quads(of: dictionary) != nil else {
        throw PDFError(.malformed, "Text markup has no quadrilaterals")
      }
    case PDFName("Square"), PDFName("Circle"):
      guard Annotation.numbers(dictionary[PDFName("Rect")], count: 4) != nil else {
        throw PDFError(.malformed, "Shape has no rectangle")
      }
    case PDFName("Line"):
      guard linePoints(of: dictionary) != nil else {
        throw PDFError(.malformed, "Line annotation has no endpoints")
      }
      guard lineEndings(of: dictionary) != nil else {
        throw PDFError(.unsupported, "Unsupported line ending style")
      }
    case PDFName("Ink"):
      guard inkStrokes(of: dictionary) != nil else {
        throw PDFError(.malformed, "Ink annotation has no strokes")
      }
    case PDFName("Text"), PDFName("FreeText"), PDFName("Stamp"):
      guard Annotation.numbers(dictionary[PDFName("Rect")], count: 4) != nil else {
        throw PDFError(.malformed, "Annotation has no rectangle")
      }
    default:
      break
    }
  }
}

/// P22-020: delete an annotation from its page. The annotation object and its
/// generated appearance are removed when nothing else references them, and
/// deletion refuses when another annotation replies to the target, so no
/// dangling /IRT relationship can be produced.
public struct DeleteAnnotationCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let annotationIndex: Int

  public init(pageID: PDFObjectID, annotationIndex: Int) {
    self.pageID = pageID
    self.annotationIndex = annotationIndex
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Delete Annotation" }

  public func validate(in graph: PDFGraph) throws {
    let entry = try AnnotationSupport.annotationEntry(
      in: graph, pageID: pageID, index: annotationIndex)
    guard let objectID = entry.objectID else { return }
    for (id, value) in graph.objects where id != objectID {
      guard case .dictionary(let dictionary) = value,
        case .reference(let target)? = dictionary[PDFName("IRT")], target == objectID
      else { continue }
      throw PDFError(.unsupported, "Deleting an annotation that has replies is not supported yet")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let entry = try AnnotationSupport.annotationEntry(
      in: graph, pageID: pageID, index: annotationIndex)
    try AnnotationSupport.removeAnnotation(
      pageID: pageID, index: annotationIndex, in: &graph)
    if let objectID = entry.objectID, !AnnotationSupport.isReferenced(objectID, in: graph) {
      var appearanceID: PDFObjectID?
      if case .dictionary(let dictionary)? = graph.objects[objectID],
        case .dictionary(let appearance)? = dictionary[PDFName("AP")],
        case .reference(let id)? = appearance[PDFName("N")]
      {
        appearanceID = id
      }
      graph.objects[objectID] = nil
      if let appearanceID, !AnnotationSupport.isReferenced(appearanceID, in: graph) {
        graph.objects[appearanceID] = nil
      }
    }
    // Keep the declared object count consistent after shrinking the graph.
    let highest = graph.objects.keys.map(\.number).max() ?? 0
    AnnotationSupport.finish(&graph, highest: highest)
    return graph
  }
}
