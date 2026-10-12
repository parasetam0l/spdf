import Foundation
import PDFCore

/// P22-003: underline and strikeout text markup from the same quadrilaterals
/// used for highlights. The generated appearance strokes a line at the
/// baseline or through the text middle, scaled to the quad height.
public enum TextMarkupStyle: String, Sendable, CaseIterable {
  case underline
  case strikeout

  var subtype: PDFName {
    switch self {
    case .underline: return PDFName("Underline")
    case .strikeout: return PDFName("StrikeOut")
    }
  }
}

public struct AddTextMarkupCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let style: TextMarkupStyle
  public let quads: [Double]
  public let color: [Double]
  public let opacity: Double
  public let contents: String?
  public let author: String?
  public let modified: String?
  public let subject: String?

  public init(
    pageID: PDFObjectID, style: TextMarkupStyle, quads: [Double], color: [Double] = [1, 0, 0],
    opacity: Double = 1, contents: String? = nil, author: String? = nil, modified: String? = nil,
    subject: String? = nil
  ) {
    self.pageID = pageID
    self.style = style
    self.quads = quads
    self.color = color
    self.opacity = opacity
    self.contents = contents
    self.author = author
    self.modified = modified
    self.subject = subject
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { style == .underline ? "Add Underline" : "Add Strikeout" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    try AnnotationSupport.validateQuads(quads)
    try AnnotationSupport.validateColor(color, label: "Markup color")
    try AnnotationSupport.validateOpacity(opacity)
    _ = try AnnotationSupport.allocate(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let allocation = try AnnotationSupport.allocate(in: graph)
    let rect = AnnotationSupport.rect(ofQuads: quads)
    var dictionary = AnnotationSupport.annotationDictionary(
      subtype: style.subtype, rect: rect, color: color, opacity: opacity,
      contents: contents, author: author, modified: modified, subject: subject,
      appearance: allocation.appearance)
    dictionary[PDFName("QuadPoints")] = .array(quads.map { .real($0) })
    graph.objects[allocation.annotation] = .dictionary(dictionary)
    graph.objects[allocation.appearance] = .stream(
      Self.appearance(style: style, quads: quads, rect: rect, color: color, opacity: opacity))
    try AnnotationSupport.appendToAnnots(
      .reference(allocation.annotation), pageID: pageID, in: &graph)
    AnnotationSupport.finish(&graph, allocation: allocation)
    return graph
  }

  static func appearance(
    style: TextMarkupStyle, quads: [Double], rect: [Double], color: [Double], opacity: Double
  ) -> PDFStream {
    var content = "q\n"
    content += "\(AnnotationSupport.number(color[0])) "
    content += "\(AnnotationSupport.number(color[1])) "
    content += "\(AnnotationSupport.number(color[2])) RG\n"
    content += "/GS0 gs\n"
    for index in stride(from: 0, to: quads.count, by: 8) {
      let ul = [quads[index] - rect[0], quads[index + 1] - rect[1]]
      let ur = [quads[index + 2] - rect[0], quads[index + 3] - rect[1]]
      let ll = [quads[index + 4] - rect[0], quads[index + 5] - rect[1]]
      let lr = [quads[index + 6] - rect[0], quads[index + 7] - rect[1]]
      let height = max(abs(ul[1] - ll[1]), abs(ur[1] - lr[1]))
      let thickness = max(0.75, height * 0.06)
      let y: Double
      switch style {
      case .underline: y = min(ll[1], lr[1]) + thickness / 2
      case .strikeout: y = (min(ll[1], lr[1]) + max(ul[1], ur[1])) / 2
      }
      content += "\(AnnotationSupport.number(thickness)) w\n"
      content += "\(AnnotationSupport.number(min(ll[0], lr[0]))) "
      content += "\(AnnotationSupport.number(y)) m\n"
      content += "\(AnnotationSupport.number(max(ll[0], lr[0]))) "
      content += "\(AnnotationSupport.number(y)) l\n"
      content += "S\n"
    }
    content += "Q\n"
    return AnnotationSupport.formAppearance(
      rect: rect, content: content,
      resources: AnnotationSupport.stateResources(opacity: opacity, blendMultiply: false))
  }
}

/// P22-004: sticky-note comments with logical text, author, and timestamp
/// plus a generated icon appearance so the note is visible without relying on
/// a reader's icon set.
public struct AddNoteCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  /// Lower-left corner of the note icon in page space.
  public let at: [Double]
  public let contents: String
  public let author: String?
  public let modified: String?
  public let subject: String?
  public let color: [Double]
  public let size: Double

  public init(
    pageID: PDFObjectID, at: [Double], contents: String, author: String? = nil,
    modified: String? = nil, subject: String? = nil, color: [Double] = [1, 0.84, 0],
    size: Double = 20
  ) {
    self.pageID = pageID
    self.at = at
    self.contents = contents
    self.author = author
    self.modified = modified
    self.subject = subject
    self.color = color
    self.size = size
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Add Note" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    guard at.count == 2, at.allSatisfy(\.isFinite) else {
      throw PDFError(.malformed, "Note position is invalid")
    }
    guard !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PDFError(.malformed, "A note needs text")
    }
    try AnnotationSupport.validateColor(color, label: "Note color")
    guard size.isFinite, size >= 8, size <= 72 else {
      throw PDFError(.malformed, "Note size must be in 8...72")
    }
    _ = try AnnotationSupport.allocate(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let allocation = try AnnotationSupport.allocate(in: graph)
    let rect = [at[0], at[1], at[0] + size, at[1] + size]
    var dictionary = AnnotationSupport.annotationDictionary(
      subtype: PDFName("Text"), rect: rect, color: color, opacity: nil,
      contents: contents, author: author, modified: modified, subject: subject,
      appearance: allocation.appearance)
    dictionary[PDFName("Name")] = .name(PDFName("Comment"))
    dictionary[PDFName("Open")] = .boolean(false)
    graph.objects[allocation.annotation] = .dictionary(dictionary)
    graph.objects[allocation.appearance] = .stream(Self.appearance(size: size, color: color))
    try AnnotationSupport.appendToAnnots(
      .reference(allocation.annotation), pageID: pageID, in: &graph)
    AnnotationSupport.finish(&graph, allocation: allocation)
    return graph
  }

  /// Icon appearance: filled background, darker border inset by half the
  /// stroke, and a folded corner so the mark reads as a note.
  static func appearance(size: Double, color: [Double]) -> PDFStream {
    let border = max(0.5, size * 0.05)
    let inset = border / 2
    var content = "q\n"
    content += "\(AnnotationSupport.number(color[0])) "
    content += "\(AnnotationSupport.number(color[1])) "
    content += "\(AnnotationSupport.number(color[2])) rg\n"
    content += "0 0 \(AnnotationSupport.number(size)) \(AnnotationSupport.number(size)) re f\n"
    content += "1 1 1 rg\n"
    content += "\(AnnotationSupport.number(size * 0.65)) 0 m "
    content += "\(AnnotationSupport.number(size)) 0 l "
    content += "\(AnnotationSupport.number(size)) \(AnnotationSupport.number(size * 0.35)) l h f\n"
    content += "0.25 0.25 0.25 RG\n"
    content += "\(AnnotationSupport.number(border)) w\n"
    content += "\(AnnotationSupport.number(inset)) \(AnnotationSupport.number(inset)) "
    content += "\(AnnotationSupport.number(size - border)) "
    content += "\(AnnotationSupport.number(size - border)) re S\n"
    content += "Q\n"
    return AnnotationSupport.formAppearance(
      rect: [0, 0, size, size], content: content,
      resources: AnnotationSupport.stateResources(opacity: 1, blendMultiply: false))
  }
}

/// P22-006: square and circle annotations with border and interior styling
/// and a generated appearance that strokes and fills in one path.
public enum ShapeKind: String, Sendable, CaseIterable {
  case square
  case circle

  var subtype: PDFName {
    switch self {
    case .square: return PDFName("Square")
    case .circle: return PDFName("Circle")
    }
  }
}

public struct AddShapeCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let kind: ShapeKind
  public let rect: [Double]
  public let borderColor: [Double]
  public let fillColor: [Double]?
  public let borderWidth: Double
  public let opacity: Double
  public let contents: String?
  public let author: String?
  public let modified: String?
  public let subject: String?

  public init(
    pageID: PDFObjectID, kind: ShapeKind, rect: [Double], borderColor: [Double] = [0, 0, 0],
    fillColor: [Double]? = nil, borderWidth: Double = 1, opacity: Double = 1,
    contents: String? = nil, author: String? = nil, modified: String? = nil,
    subject: String? = nil
  ) {
    self.pageID = pageID
    self.kind = kind
    self.rect = rect
    self.borderColor = borderColor
    self.fillColor = fillColor
    self.borderWidth = borderWidth
    self.opacity = opacity
    self.contents = contents
    self.author = author
    self.modified = modified
    self.subject = subject
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { kind == .square ? "Add Square" : "Add Circle" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    guard rect.count == 4, rect.allSatisfy(\.isFinite),
      rect[2] > rect[0], rect[3] > rect[1]
    else {
      throw PDFError(.malformed, "Shape rectangle is invalid")
    }
    try AnnotationSupport.validateColor(borderColor, label: "Border color")
    if let fillColor { try AnnotationSupport.validateColor(fillColor, label: "Fill color") }
    try AnnotationSupport.validateBorderWidth(borderWidth)
    try AnnotationSupport.validateOpacity(opacity)
    guard borderWidth > 0 || fillColor != nil else {
      throw PDFError(.malformed, "A shape needs a border or a fill")
    }
    guard borderWidth <= min(rect[2] - rect[0], rect[3] - rect[1]) else {
      throw PDFError(.malformed, "Shape border is wider than the shape")
    }
    _ = try AnnotationSupport.allocate(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let allocation = try AnnotationSupport.allocate(in: graph)
    var dictionary = AnnotationSupport.annotationDictionary(
      subtype: kind.subtype, rect: rect, color: borderColor, opacity: opacity,
      contents: contents, author: author, modified: modified, subject: subject,
      appearance: allocation.appearance)
    if let fillColor { dictionary[PDFName("IC")] = .array(fillColor.map { .real($0) }) }
    dictionary[PDFName("BS")] = .dictionary([
      PDFName("Type"): .name(PDFName("Border")),
      PDFName("W"): .real(borderWidth),
    ])
    dictionary[PDFName("Border")] = .array([
      .integer(0), .integer(0), .real(borderWidth),
    ])
    graph.objects[allocation.annotation] = .dictionary(dictionary)
    graph.objects[allocation.appearance] = .stream(
      Self.appearance(
        kind: kind, rect: rect, borderColor: borderColor, fillColor: fillColor,
        borderWidth: borderWidth, opacity: opacity))
    try AnnotationSupport.appendToAnnots(
      .reference(allocation.annotation), pageID: pageID, in: &graph)
    AnnotationSupport.finish(&graph, allocation: allocation)
    return graph
  }

  static func appearance(
    kind: ShapeKind, rect: [Double], borderColor: [Double], fillColor: [Double]?,
    borderWidth: Double, opacity: Double
  ) -> PDFStream {
    let width = rect[2] - rect[0]
    let height = rect[3] - rect[1]
    // Inset by half the stroke so the border stays inside the annotation rect.
    let inset = borderWidth / 2
    var content = "q\n"
    if let fillColor {
      content += "\(AnnotationSupport.number(fillColor[0])) "
      content += "\(AnnotationSupport.number(fillColor[1])) "
      content += "\(AnnotationSupport.number(fillColor[2])) rg\n"
    }
    content += "\(AnnotationSupport.number(borderColor[0])) "
    content += "\(AnnotationSupport.number(borderColor[1])) "
    content += "\(AnnotationSupport.number(borderColor[2])) RG\n"
    content += "\(AnnotationSupport.number(borderWidth)) w\n"
    content += "/GS0 gs\n"
    switch kind {
    case .square:
      content += "\(AnnotationSupport.number(inset)) \(AnnotationSupport.number(inset)) "
      content += "\(AnnotationSupport.number(width - borderWidth)) "
      content += "\(AnnotationSupport.number(height - borderWidth)) re\n"
    case .circle:
      content += AnnotationSupport.ellipsePath(
        cx: width / 2, cy: height / 2, rx: (width - borderWidth) / 2,
        ry: (height - borderWidth) / 2)
    }
    if fillColor != nil && borderWidth > 0 {
      content += "B\n"
    } else if fillColor != nil {
      content += "f\n"
    } else {
      content += "S\n"
    }
    content += "Q\n"
    return AnnotationSupport.formAppearance(
      rect: rect, content: content,
      resources: AnnotationSupport.stateResources(opacity: opacity, blendMultiply: false))
  }
}

/// P22-007: line annotations with supported ending styles. The generated
/// appearance strokes the line and fills closed arrowheads with the line
/// color.
public enum LineEnding: String, Sendable, CaseIterable {
  case none
  case closedArrow

  var pdfName: PDFName {
    switch self {
    case .none: return PDFName("None")
    case .closedArrow: return PDFName("ClosedArrow")
    }
  }
}

public struct AddLineCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let from: [Double]
  public let to: [Double]
  public let startEnding: LineEnding
  public let endEnding: LineEnding
  public let color: [Double]
  public let borderWidth: Double
  public let opacity: Double
  public let contents: String?
  public let author: String?
  public let modified: String?
  public let subject: String?

  public init(
    pageID: PDFObjectID, from: [Double], to: [Double], startEnding: LineEnding = .none,
    endEnding: LineEnding = .closedArrow, color: [Double] = [0, 0, 0], borderWidth: Double = 1,
    opacity: Double = 1, contents: String? = nil, author: String? = nil, modified: String? = nil,
    subject: String? = nil
  ) {
    self.pageID = pageID
    self.from = from
    self.to = to
    self.startEnding = startEnding
    self.endEnding = endEnding
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
  public var name: String { "Add Line" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    guard from.count == 2, to.count == 2, from.allSatisfy(\.isFinite), to.allSatisfy(\.isFinite)
    else {
      throw PDFError(.malformed, "Line endpoints are invalid")
    }
    guard from != to else {
      throw PDFError(.malformed, "Line endpoints must differ")
    }
    try AnnotationSupport.validateColor(color, label: "Line color")
    try AnnotationSupport.validateBorderWidth(borderWidth)
    try AnnotationSupport.validateOpacity(opacity)
    guard borderWidth > 0 || startEnding != .none || endEnding != .none else {
      throw PDFError(.malformed, "A line needs a visible stroke or an arrowhead")
    }
    _ = try AnnotationSupport.allocate(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let allocation = try AnnotationSupport.allocate(in: graph)
    let geometry = Self.geometry(
      from: from, to: to, borderWidth: borderWidth, startEnding: startEnding,
      endEnding: endEnding)
    var dictionary = AnnotationSupport.annotationDictionary(
      subtype: PDFName("Line"), rect: geometry.rect, color: color, opacity: opacity,
      contents: contents, author: author, modified: modified, subject: subject,
      appearance: allocation.appearance)
    dictionary[PDFName("L")] = .array([from[0], from[1], to[0], to[1]].map { .real($0) })
    dictionary[PDFName("LE")] = .array([
      .name(startEnding.pdfName), .name(endEnding.pdfName),
    ])
    dictionary[PDFName("IC")] = .array(color.map { .real($0) })
    dictionary[PDFName("BS")] = .dictionary([
      PDFName("Type"): .name(PDFName("Border")),
      PDFName("W"): .real(borderWidth),
    ])
    graph.objects[allocation.annotation] = .dictionary(dictionary)
    graph.objects[allocation.appearance] = .stream(
      Self.appearance(
        from: from, to: to, rect: geometry.rect, startArrow: geometry.startArrow,
        endArrow: geometry.endArrow, color: color, borderWidth: borderWidth, opacity: opacity))
    try AnnotationSupport.appendToAnnots(
      .reference(allocation.annotation), pageID: pageID, in: &graph)
    AnnotationSupport.finish(&graph, allocation: allocation)
    return graph
  }

  /// Rect union of the endpoints and arrowhead triangles, padded by half the
  /// stroke width, plus the triangles themselves for the appearance.
  static func geometry(
    from: [Double], to: [Double], borderWidth: Double, startEnding: LineEnding,
    endEnding: LineEnding
  ) -> (rect: [Double], startArrow: [Double]?, endArrow: [Double]?) {
    let dx = to[0] - from[0]
    let dy = to[1] - from[1]
    let length = (dx * dx + dy * dy).squareRoot()
    let direction = [dx / length, dy / length]
    let perpendicular = [-direction[1], direction[0]]
    let arrowLength = max(6, borderWidth * 4)
    func triangle(tip: [Double]) -> [Double] {
      let base = [
        tip[0] - direction[0] * arrowLength, tip[1] - direction[1] * arrowLength,
      ]
      let half = arrowLength * 0.4
      return [
        tip[0], tip[1],
        base[0] + perpendicular[0] * half, base[1] + perpendicular[1] * half,
        base[0] - perpendicular[0] * half, base[1] - perpendicular[1] * half,
      ]
    }
    let startArrow = startEnding == .closedArrow ? triangle(tip: from) : nil
    let endArrow = endEnding == .closedArrow ? triangle(tip: to) : nil
    var xs = [from[0], to[0]]
    var ys = [from[1], to[1]]
    for arrow in [startArrow, endArrow].compactMap({ $0 }) {
      xs.append(contentsOf: [arrow[0], arrow[2], arrow[4]])
      ys.append(contentsOf: [arrow[1], arrow[3], arrow[5]])
    }
    let pad = max(borderWidth, 1) / 2
    return (
      [xs.min()! - pad, ys.min()! - pad, xs.max()! + pad, ys.max()! + pad], startArrow, endArrow
    )
  }

  static func appearance(
    from: [Double], to: [Double], rect: [Double], startArrow: [Double]?, endArrow: [Double]?,
    color: [Double], borderWidth: Double, opacity: Double
  ) -> PDFStream {
    func local(_ x: Double, _ y: Double) -> String {
      "\(AnnotationSupport.number(x - rect[0])) \(AnnotationSupport.number(y - rect[1]))"
    }
    var content = "q\n"
    content += "/GS0 gs\n"
    if borderWidth > 0 {
      content += "\(AnnotationSupport.number(color[0])) "
      content += "\(AnnotationSupport.number(color[1])) "
      content += "\(AnnotationSupport.number(color[2])) RG\n"
      content += "\(AnnotationSupport.number(borderWidth)) w\n"
      content += "\(local(from[0], from[1])) m\n"
      content += "\(local(to[0], to[1])) l\nS\n"
    }
    if startArrow != nil || endArrow != nil {
      content += "\(AnnotationSupport.number(color[0])) "
      content += "\(AnnotationSupport.number(color[1])) "
      content += "\(AnnotationSupport.number(color[2])) rg\n"
      for arrow in [startArrow, endArrow].compactMap({ $0 }) {
        content += "\(local(arrow[0], arrow[1])) m\n"
        content += "\(local(arrow[2], arrow[3])) l\n"
        content += "\(local(arrow[4], arrow[5])) l\n"
        content += "h f\n"
      }
    }
    content += "Q\n"
    return AnnotationSupport.formAppearance(
      rect: rect, content: content,
      resources: AnnotationSupport.stateResources(opacity: opacity, blendMultiply: false))
  }
}
