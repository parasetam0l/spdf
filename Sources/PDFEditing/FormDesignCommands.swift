import Foundation
import PDFCore

// FRM-02: core support for the direct form-design canvas.
//
// The canvas edits the canonical AcroForm tree through ordinary edit commands,
// so every committed gesture is one undoable transaction and page annotations,
// field dictionaries and appearances stay consistent. Geometry, guide snapping,
// tab ordering and multi-widget selection are pure functions so the canvas and
// its tests share one implementation.

/// FRM-02: one canonical widget with the data a canvas needs.
public struct FormWidgetDescriptor: Sendable, Equatable, Identifiable {
  public let fieldName: String
  public let fieldKind: FormField.Kind
  public let widgetObjectID: PDFObjectID?
  public let widgetIndex: Int
  public let pageIndex: Int
  public let pageID: PDFObjectID
  public let pageBounds: [Double]
  public let rect: [Double]
  public let label: String?
  public let isReadOnly: Bool
  public let isMultiline: Bool

  public init(
    fieldName: String, fieldKind: FormField.Kind, widgetObjectID: PDFObjectID?,
    widgetIndex: Int, pageIndex: Int, pageID: PDFObjectID, pageBounds: [Double],
    rect: [Double], label: String?, isReadOnly: Bool, isMultiline: Bool
  ) {
    self.fieldName = fieldName
    self.fieldKind = fieldKind
    self.widgetObjectID = widgetObjectID
    self.widgetIndex = widgetIndex
    self.pageIndex = pageIndex
    self.pageID = pageID
    self.pageBounds = pageBounds
    self.rect = rect
    self.label = label
    self.isReadOnly = isReadOnly
    self.isMultiline = isMultiline
  }

  public var id: String {
    fieldName + "#" + String(widgetIndex) + "/" + String(pageIndex)
  }

  public var width: Double { rect[2] - rect[0] }
  public var height: Double { rect[3] - rect[1] }
  public var centerX: Double { (rect[0] + rect[2]) / 2 }
  public var centerY: Double { (rect[1] + rect[3]) / 2 }
}

/// FRM-02: reads the widgets and labels the design canvas draws. Read-only.
public enum FormDesignInventory {
  /// Every widget on the given pages, in canonical field order.
  public static func widgets(in graph: PDFGraph, pageIDs: [PDFObjectID]) throws
    -> [FormWidgetDescriptor]
  {
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    let attributes = PDFDocumentInventory.pageAttributes(pageIDs: pageIDs, in: graph)
    var pageBounds: [PDFObjectID: [Double]] = [:]
    for attribute in attributes {
      pageBounds[attribute.pageObjectID] = attribute.displayBox
    }
    var descriptions: [FormWidgetDescriptor] = []
    for field in fields {
      let label = tooltip(for: field, in: graph)
      for (index, widget) in field.widgets.enumerated() {
        guard let rect = widget.rect, let pageIndex = widget.pageIndex,
          pageIDs.indices.contains(pageIndex)
        else { continue }
        let pageID = pageIDs[pageIndex]
        descriptions.append(
          FormWidgetDescriptor(
            fieldName: field.name, fieldKind: field.kind, widgetObjectID: widget.objectID,
            widgetIndex: index, pageIndex: pageIndex, pageID: pageID,
            pageBounds: pageBounds[pageID] ?? [0, 0, 612, 792], rect: rect, label: label,
            isReadOnly: field.isReadOnly, isMultiline: field.isMultiline))
      }
    }
    return descriptions
  }

  /// The field's tooltip/user name (/TU), when present.
  public static func tooltip(for field: FormField, in graph: PDFGraph) -> String? {
    guard let fieldID = field.fieldID, case .dictionary(let dictionary)? = graph.objects[fieldID],
      case .string(let data)? = dictionary[PDFName("TU")]
    else { return nil }
    let text = AnnotationText.decode(data).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }
}

/// FRM-02: set one widget's rectangle. The appearance is regenerated at the new
/// size so a moved or resized field does not draw stale content.
public struct SetFormWidgetRectCommand: PDFEditCommand, Equatable, Sendable {
  public let fieldName: String
  /// Preferred identity; the widget index is used only when the object identity
  /// is nil or no longer belongs to the field.
  public let widgetObjectID: PDFObjectID?
  public let widgetIndex: Int
  public let rect: [Double]

  public init(
    fieldName: String, widgetObjectID: PDFObjectID? = nil, widgetIndex: Int = 0, rect: [Double]
  ) {
    self.fieldName = fieldName
    self.widgetObjectID = widgetObjectID
    self.widgetIndex = widgetIndex
    self.rect = rect
  }

  public var name: String { "Move or Resize Form Field" }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] {
    if let pageID = FormDesignSupport.widgetPageID(
      fieldName: fieldName, widgetObjectID: widgetObjectID, widgetIndex: widgetIndex, in: graph)
    {
      return [pageID]
    }
    return []
  }

  public func validate(in graph: PDFGraph) throws {
    let widget = try FormDesignSupport.resolveWidget(
      fieldName: fieldName, widgetObjectID: widgetObjectID, widgetIndex: widgetIndex, in: graph)
    try FormDesignSupport.validate(rect: rect, onPageID: widget.pageID, in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let widget = try FormDesignSupport.resolveWidget(
      fieldName: fieldName, widgetObjectID: widgetObjectID, widgetIndex: widgetIndex, in: graph)
    guard case .dictionary(var dictionary)? = graph.objects[widget.widgetID] else {
      throw PDFError(.malformed, "The widget dictionary is missing")
    }
    dictionary[PDFName("Rect")] = .array(rect.map { PDFValue.real($0) })
    graph.objects[widget.widgetID] = .dictionary(dictionary)
    try FormDesignSupport.refreshAppearance(
      widgetID: widget.widgetID, fieldName: fieldName, in: &graph)
    return graph
  }
}

/// FRM-02: set or clear a field's tooltip/user name (/TU). This is the label the
/// canvas and the Forms sidebar show, and it is the accessible name of the
/// widget in readers.
public struct SetFormFieldTooltipCommand: PDFEditCommand, Equatable, Sendable {
  public let fieldName: String
  /// nil or empty clears the tooltip.
  public let tooltip: String?

  public init(fieldName: String, tooltip: String?) {
    self.fieldName = fieldName
    self.tooltip = tooltip
  }

  public var name: String { "Set Form Field Label" }

  public func validate(in graph: PDFGraph) throws {
    guard FormAuthoringSupport.findField(named: fieldName, in: graph) != nil else {
      throw PDFError(.malformed, "Form field is missing")
    }
    if let tooltip, tooltip.count > 512 {
      throw PDFError(.malformed, "The field label is longer than the supported profile")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    guard let fieldID = FormAuthoringSupport.findField(named: fieldName, in: graph),
      case .dictionary(var field)? = graph.objects[fieldID]
    else { throw PDFError(.malformed, "Form field is missing") }
    let trimmed = tooltip?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmed, !trimmed.isEmpty {
      field[PDFName("TU")] = .string(AnnotationText.encode(trimmed))
    } else {
      field.removeValue(forKey: PDFName("TU"))
    }
    graph.objects[fieldID] = .dictionary(field)
    return graph
  }
}

// MARK: - Widget resolution and appearance refresh

enum FormDesignSupport {
  struct ResolvedWidget {
    let field: FormField
    let widget: FormWidget
    let widgetID: PDFObjectID
    let pageID: PDFObjectID
  }

  static func resolveWidget(
    fieldName: String, widgetObjectID: PDFObjectID?, widgetIndex: Int, in graph: PDFGraph
  ) throws -> ResolvedWidget {
    let pageIDs = try PageTreeView(graph: graph).pages
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    guard let field = fields.first(where: { $0.name == fieldName }) else {
      throw PDFError(.malformed, "Form field " + fieldName + " is missing")
    }
    guard !field.widgets.isEmpty else {
      throw PDFError(.malformed, "Form field " + fieldName + " has no widgets")
    }
    var widget: FormWidget?
    if let widgetObjectID {
      widget = field.widgets.first { $0.objectID == widgetObjectID }
    }
    if widget == nil, field.widgets.indices.contains(widgetIndex) {
      widget = field.widgets[widgetIndex]
    }
    guard let widget, let widgetID = widget.objectID, let pageIndex = widget.pageIndex,
      pageIDs.indices.contains(pageIndex)
    else {
      throw PDFError(.malformed, "The widget is not attached to a page")
    }
    return ResolvedWidget(
      field: field, widget: widget, widgetID: widgetID, pageID: pageIDs[pageIndex])
  }

  static func widgetPageID(
    fieldName: String, widgetObjectID: PDFObjectID?, widgetIndex: Int, in graph: PDFGraph
  ) -> PDFObjectID? {
    try? resolveWidget(
      fieldName: fieldName, widgetObjectID: widgetObjectID, widgetIndex: widgetIndex,
      in: graph
    ).pageID
  }

  static func validate(rect: [Double], onPageID pageID: PDFObjectID, in graph: PDFGraph)
    throws
  {
    guard rect.count == 4, rect.allSatisfy(\.isFinite), rect[2] - rect[0] >= 4,
      rect[3] - rect[1] >= 4
    else {
      throw PDFError(.malformed, "The field needs a rectangle at least 4 by 4 points")
    }
    let bounds = FormFieldDetection.pageBounds(pageID: pageID, in: graph)
    guard FormDetectionGeometry.contains(inner: rect, outer: bounds, tolerance: 0.5) else {
      throw PDFError(
        .malformed, "The field must stay inside the page box; drag it back onto the page")
    }
  }

  /// Rebuild the widget's normal appearance for its new size, preserving the
  /// field's value, alignment, multiline and comb profile where supported.
  static func refreshAppearance(
    widgetID: PDFObjectID, fieldName: String, in graph: inout PDFGraph
  ) throws {
    guard case .dictionary(let widget)? = graph.objects[widgetID],
      let rect = Annotation.numbers(widget[PDFName("Rect")], count: 4)
    else { return }
    guard let pageIDs = try? PageTreeView(graph: graph).pages,
      let field = try? FormInventory.fields(in: graph, pageIDs: pageIDs)
        .first(where: { $0.name == fieldName })
    else { return }
    var nextNumber = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    switch field.kind {
    case .text:
      let da = SetFormTextCommand.parseDA(SetFormTextCommand.daValue(for: field, in: graph))
      let value = field.stringValue ?? ""
      let appearance = SetFormTextCommand.textAppearance(
        text: value, rect: rect, multiline: field.isMultiline, da: da,
        fontID: try helveticaID(in: &graph, nextNumber: &nextNumber),
        alignment: FormDesignSupport.alignment(field: field, in: graph), comb: field.isComb,
        maxLength: field.maxLength)
      nextNumber = try SetFormTextCommand.installAppearance(
        appearance, widgetID: widgetID, in: &graph, nextNumber: nextNumber)
    case .choice:
      let da = SetFormTextCommand.parseDA(SetFormTextCommand.daValue(for: field, in: graph))
      let display = field.selectedOption?.display ?? field.stringValue ?? ""
      let appearance = SetFormTextCommand.textAppearance(
        text: display, rect: rect, multiline: false, da: da,
        fontID: try helveticaID(in: &graph, nextNumber: &nextNumber))
      nextNumber = try SetFormTextCommand.installAppearance(
        appearance, widgetID: widgetID, in: &graph, nextNumber: nextNumber)
    case .button where !field.isPushButton:
      nextNumber = try FormAuthoringSupport.regenerateButtonAppearances(
        widgetID: widgetID, in: &graph, nextNumber: nextNumber)
    case .button:
      var mk: [PDFName: PDFValue] = [:]
      if case .dictionary(let existing)? = widget[PDFName("MK")] { mk = existing }
      let caption: String
      if case .string(let data)? = mk[PDFName("CA")] {
        caption = AnnotationText.decode(data)
      } else {
        caption = ""
      }
      let appearance = FormAuthoringSupport.pushButtonAppearance(
        caption: caption, rect: rect, mk: mk)
      nextNumber = try SetFormTextCommand.installAppearance(
        appearance, widgetID: widgetID, in: &graph, nextNumber: nextNumber)
    case .signature, .unknown:
      break
    }
    graph.trailer[PDFName("Size")] = .integer(Int64(max(nextNumber, (graph.objects.keys.map(\.number).max() ?? 0) + 1)))
  }

  static func alignment(field: FormField, in graph: PDFGraph) -> Int {
    guard let fieldID = field.fieldID, case .dictionary(let dictionary)? = graph.objects[fieldID],
      case .integer(let value)? = dictionary[PDFName("Q")]
    else { return 0 }
    return Int(value)
  }

  static func helveticaID(in graph: inout PDFGraph, nextNumber: inout Int) throws -> PDFObjectID {
    if let existing = AnnotationSupport.helveticaFontID(in: graph) { return existing }
    let id = PDFObjectID(nextNumber)
    nextNumber += 1
    graph.objects[id] = .dictionary(AnnotationSupport.helveticaFontDictionary())
    return id
  }
}

// MARK: - Canvas geometry

/// FRM-02: resize handles around a selected widget.
public enum FormResizeHandle: String, Sendable, Equatable, CaseIterable {
  case bottomLeft
  case bottom
  case bottomRight
  case right
  case topRight
  case top
  case topLeft
  case left
}

/// FRM-02: pure canvas geometry: snapping, guides, drag rectangles and
/// multi-selection transforms.
public enum FormDesignGeometry {
  public static let minimumWidgetSize: Double = 6

  public static func union(_ rects: [[Double]]) -> [Double]? {
    let valid = rects.filter { $0.count == 4 && $0.allSatisfy(\.isFinite) }
    guard var result = valid.first else { return nil }
    for rect in valid.dropFirst() {
      result = [
        min(result[0], rect[0]), min(result[1], rect[1]), max(result[2], rect[2]),
        max(result[3], rect[3]),
      ]
    }
    return result
  }

  public static func normalizedRect(from start: [Double], to end: [Double]) -> [Double] {
    [
      min(start[0], end[0]), min(start[1], end[1]), max(start[0], end[0]),
      max(start[1], end[1]),
    ]
  }

  public static func translated(_ rect: [Double], by offset: [Double]) -> [Double] {
    [rect[0] + offset[0], rect[1] + offset[1], rect[2] + offset[0], rect[3] + offset[1]]
  }

  /// Clamp a rect inside a page box, shrinking it if it is larger than the page.
  public static func clamped(_ rect: [Double], to bounds: [Double]) -> [Double] {
    guard rect.count == 4, bounds.count == 4 else { return rect }
    var width = min(rect[2] - rect[0], bounds[2] - bounds[0])
    var height = min(rect[3] - rect[1], bounds[3] - bounds[1])
    width = max(width, minimumWidgetSize)
    height = max(height, minimumWidgetSize)
    var x = min(max(rect[0], bounds[0]), bounds[2] - width)
    var y = min(max(rect[1], bounds[1]), bounds[3] - height)
    if !x.isFinite { x = bounds[0] }
    if !y.isFinite { y = bounds[1] }
    return [x, y, x + width, y + height]
  }

  /// Apply a handle drag to one rect, keeping the opposite edge anchored.
  public static func resized(
    _ rect: [Double], handle: FormResizeHandle, by delta: [Double],
    minimumSize: Double = FormDesignGeometry.minimumWidgetSize
  ) -> [Double] {
    var result = rect
    switch handle {
    case .bottomLeft:
      result[0] = min(rect[0] + delta[0], rect[2] - minimumSize)
      result[1] = min(rect[1] + delta[1], rect[3] - minimumSize)
    case .bottom:
      result[1] = min(rect[1] + delta[1], rect[3] - minimumSize)
    case .bottomRight:
      result[2] = max(rect[2] + delta[0], rect[0] + minimumSize)
      result[1] = min(rect[1] + delta[1], rect[3] - minimumSize)
    case .right:
      result[2] = max(rect[2] + delta[0], rect[0] + minimumSize)
    case .topRight:
      result[2] = max(rect[2] + delta[0], rect[0] + minimumSize)
      result[3] = max(rect[3] + delta[1], rect[1] + minimumSize)
    case .top:
      result[3] = max(rect[3] + delta[1], rect[1] + minimumSize)
    case .topLeft:
      result[0] = min(rect[0] + delta[0], rect[2] - minimumSize)
      result[3] = max(rect[3] + delta[1], rect[1] + minimumSize)
    case .left:
      result[0] = min(rect[0] + delta[0], rect[2] - minimumSize)
    }
    return result
  }

  /// Scale a group of rects proportionally when the group's bounding box is
  /// resized. Rect edges keep their relative position inside the group.
  public static func scaled(
    _ rects: [[Double]], from originalBounds: [Double], to newBounds: [Double]
  ) -> [[Double]] {
    let originalWidth = originalBounds[2] - originalBounds[0]
    let originalHeight = originalBounds[3] - originalBounds[1]
    let newWidth = newBounds[2] - newBounds[0]
    let newHeight = newBounds[3] - newBounds[1]
    let xScale = originalWidth > 0 ? newWidth / originalWidth : 1
    let yScale = originalHeight > 0 ? newHeight / originalHeight : 1
    return rects.map { rect in
      let x0 = newBounds[0] + (rect[0] - originalBounds[0]) * xScale
      let x1 = newBounds[0] + (rect[2] - originalBounds[0]) * xScale
      let y0 = newBounds[1] + (rect[1] - originalBounds[1]) * yScale
      let y1 = newBounds[1] + (rect[3] - originalBounds[1]) * yScale
      return [
        min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1),
      ]
    }
  }

  /// FRM-02: alignment guides drawn while dragging: page edges and center,
  /// other widgets' edges and centers, and an optional point grid.
  public struct Guides: Sendable, Equatable {
    public var vertical: [Double] = []
    public var horizontal: [Double] = []
    public init() {}
  }

  public struct SnapResult: Sendable, Equatable {
    public let rect: [Double]
    public let verticalGuide: Double?
    public let horizontalGuide: Double?
    public init(rect: [Double], verticalGuide: Double?, horizontalGuide: Double?) {
      self.rect = rect
      self.verticalGuide = verticalGuide
      self.horizontalGuide = horizontalGuide
    }
  }

  public static func guides(
    pageBounds: [Double], widgetRects: [[Double]], grid: Double? = nil
  ) -> Guides {
    var guides = Guides()
    guard pageBounds.count == 4 else { return guides }
    guides.vertical = [pageBounds[0], (pageBounds[0] + pageBounds[2]) / 2, pageBounds[2]]
    guides.horizontal = [pageBounds[1], (pageBounds[1] + pageBounds[3]) / 2, pageBounds[3]]
    for rect in widgetRects {
      guard rect.count == 4 else { continue }
      guides.vertical.append(contentsOf: [rect[0], (rect[0] + rect[2]) / 2, rect[2]])
      guides.horizontal.append(contentsOf: [rect[1], (rect[1] + rect[3]) / 2, rect[3]])
    }
    if let grid, grid > 0 {
      var x = pageBounds[0]
      while x <= pageBounds[2] {
        guides.vertical.append(x)
        x += grid
      }
      var y = pageBounds[1]
      while y <= pageBounds[3] {
        guides.horizontal.append(y)
        y += grid
      }
    }
    guides.vertical = Array(Set(guides.vertical.map { ($0 * 100).rounded() / 100 })).sorted()
    guides.horizontal = Array(Set(guides.horizontal.map { ($0 * 100).rounded() / 100 })).sorted()
    return guides
  }

  /// Snap a dragged rect's edges and centers to the nearest guide inside the
  /// tolerance. The moved rect is returned with the guide coordinates the
  /// canvas should draw.
  public static func snap(
    _ rect: [Double], guides: Guides, tolerance: Double = 4
  ) -> SnapResult {
    guard rect.count == 4, tolerance > 0 else {
      return SnapResult(rect: rect, verticalGuide: nil, horizontalGuide: nil)
    }
    var result = rect
    var verticalGuide: Double?
    var bestX = Double.infinity
    for guide in guides.vertical {
      for edge in [rect[0], (rect[0] + rect[2]) / 2, rect[2]] {
        let delta = guide - edge
        guard abs(delta) <= tolerance, abs(delta) < abs(bestX) else { continue }
        bestX = delta
        verticalGuide = guide
      }
    }
    if verticalGuide != nil, bestX.isFinite {
      result[0] += bestX
      result[2] += bestX
    }
    var horizontalGuide: Double?
    var bestY = Double.infinity
    for guide in guides.horizontal {
      for edge in [rect[1], (rect[1] + rect[3]) / 2, rect[3]] {
        let delta = guide - edge
        guard abs(delta) <= tolerance, abs(delta) < abs(bestY) else { continue }
        bestY = delta
        horizontalGuide = guide
      }
    }
    if horizontalGuide != nil, bestY.isFinite {
      result[1] += bestY
      result[3] += bestY
    }
    return SnapResult(rect: result, verticalGuide: verticalGuide, horizontalGuide: horizontalGuide)
  }
}

// MARK: - Selection

/// FRM-02: a canvas selection over canonical widgets. Selection is a value; the
/// commands it builds are ordinary widget-rectangle edits grouped in one
/// transaction so a multi-widget move is one Undo step.
public struct FormWidgetSelection: Sendable, Equatable {
  public private(set) var widgets: [FormWidgetDescriptor] = []

  public init() {}

  public init(widgets: [FormWidgetDescriptor]) {
    self.widgets = widgets
  }

  public var isEmpty: Bool { widgets.isEmpty }
  public var count: Int { widgets.count }
  public var fieldNames: [String] { Array(Set(widgets.map(\.fieldName))).sorted() }

  public func contains(_ widget: FormWidgetDescriptor) -> Bool {
    widgets.contains { $0.id == widget.id }
  }

  public mutating func select(_ widget: FormWidgetDescriptor) {
    guard !contains(widget) else { return }
    widgets.append(widget)
  }

  public mutating func add(_ widget: FormWidgetDescriptor) {
    select(widget)
  }

  public mutating func toggle(_ widget: FormWidgetDescriptor) {
    if contains(widget) {
      widgets.removeAll { $0.id == widget.id }
    } else {
      widgets.append(widget)
    }
  }

  public mutating func removeAll() { widgets.removeAll() }

  /// Marquee selection: every widget intersecting the rectangle is selected.
  public mutating func selectIntersecting(_ rect: [Double], of candidates: [FormWidgetDescriptor]) {
    widgets = candidates.filter {
      FormDetectionGeometry.intersectionArea(rect, $0.rect) > 0
    }
  }

  /// Topmost widget under a point, used for click selection.
  public static func widget(
    at point: [Double], among candidates: [FormWidgetDescriptor]
  ) -> FormWidgetDescriptor? {
    candidates.last { widget in
      point.count == 2 && point[0] >= widget.rect[0] && point[0] <= widget.rect[2]
        && point[1] >= widget.rect[1] && point[1] <= widget.rect[3]
    }
  }

  public var bounds: [Double]? { FormDesignGeometry.union(widgets.map(\.rect)) }

  /// One command per selected widget, translated by the offset and clamped
  /// inside its own page. The resulting transaction is one Undo step.
  public func moveCommands(by offset: [Double]) -> [any PDFEditCommand] {
    widgets.map { widget in
      let moved = FormDesignGeometry.translated(widget.rect, by: offset)
      return SetFormWidgetRectCommand(
        fieldName: widget.fieldName, widgetObjectID: widget.widgetObjectID,
        widgetIndex: widget.widgetIndex,
        rect: FormDesignGeometry.clamped(moved, to: widget.pageBounds))
    }
  }

  public func resizeCommands(
    handle: FormResizeHandle, by delta: [Double], minimumSize: Double = FormDesignGeometry.minimumWidgetSize
  ) -> [any PDFEditCommand] {
    guard let originalBounds = bounds else { return [] }
    let dragged = FormDesignGeometry.resized(
      originalBounds, handle: handle, by: delta, minimumSize: minimumSize)
    let newRects = FormDesignGeometry.scaled(
      widgets.map(\.rect), from: originalBounds, to: dragged)
    return zip(widgets, newRects).map { widget, rect in
      SetFormWidgetRectCommand(
        fieldName: widget.fieldName, widgetObjectID: widget.widgetObjectID,
        widgetIndex: widget.widgetIndex,
        rect: FormDesignGeometry.clamped(rect, to: widget.pageBounds))
    }
  }
}

// MARK: - Tab order

/// FRM-02: field tab order helpers. The canonical order is the one readers use
/// when the page does not request structure order; the canvas shows it as
/// numbered badges and commits a reordered list as one transaction.
public enum FormTabOrder {
  /// The document's current field order.
  public static func current(fields: [FormField]) -> [String] {
    fields.map(\.name)
  }

  /// A reading-order suggestion: page order, then top-to-bottom and
  /// left-to-right within the page. A multi-widget field is one tab stop.
  public static func suggested(pageIDs: [PDFObjectID], fields: [FormField]) -> [String] {
    func anchor(_ field: FormField) -> (page: Int, top: Double, left: Double) {
      let widgets = field.widgets.compactMap { widget -> (page: Int, rect: [Double])? in
        guard let page = widget.pageIndex, let rect = widget.rect else { return nil }
        return (page, rect)
      }
      if let first = widgets.first {
        return (first.page, first.rect[3], first.rect[0])
      }
      return (pageIDs.count, 0, 0)
    }
    return fields.sorted { lhs, rhs in
      let a = anchor(lhs)
      let b = anchor(rhs)
      if a.page != b.page { return a.page < b.page }
      if abs(a.top - b.top) > 2 { return a.top > b.top }
      return a.left < b.left
    }.map(\.name)
  }

  public static func validate(_ order: [String], fields: [FormField]) -> String? {
    let available = Set(fields.map(\.name))
    guard order.count == available.count else {
      return "The tab order must list every field exactly once."
    }
    guard Set(order).count == order.count else {
      return "The tab order lists a field twice."
    }
    for name in order where !available.contains(name) {
      return "The tab order names an unknown field: " + name
    }
    return nil
  }

  /// One transaction for a tab-order change.
  public static func transaction(order: [String], fields: [FormField]) -> PDFTransaction? {
    guard validate(order, fields: fields) == nil else { return nil }
    return PDFTransaction([ReorderFormFieldsCommand(order: order)])
  }
}

// MARK: - Authoring from the canvas

/// FRM-02: geometry for drawing new fields directly on the page.
public enum FormCanvasAuthoring {
  /// Draw a radio group row inside a dragged rectangle: one square option per
  /// value, evenly spaced with a gap.
  public static func radioRects(in rect: [Double], count: Int) -> [[Double]] {
    guard rect.count == 4, count > 0 else { return [] }
    let row = FormDesignGeometry.normalizedRect(from: [rect[0], rect[1]], to: [rect[2], rect[3]])
    let height = min(max(row[3] - row[1], FormDesignGeometry.minimumWidgetSize), 22)
    let side = height
    let available = max(row[2] - row[0], side)
    let spacing = count > 1 ? max(4, (available - side * Double(count)) / Double(count - 1)) : 0
    let startX = row[0]
    let y = row[1] + max(0, (row[3] - row[1] - side) / 2)
    return (0..<count).map { index in
      let x = startX + Double(index) * (side + spacing)
      return [x, y, x + side, y + side]
    }
  }

  /// Normalize a canvas drag into a field rectangle with the minimum size.
  public static func draggedRect(
    from start: [Double], to end: [Double],
    minimumSize: Double = FormDesignGeometry.minimumWidgetSize * 2
  ) -> [Double] {
    var rect = FormDesignGeometry.normalizedRect(from: start, to: end)
    if rect[2] - rect[0] < minimumSize { rect[2] = rect[0] + minimumSize }
    if rect[3] - rect[1] < minimumSize { rect[3] = rect[1] + minimumSize }
    return rect
  }

  /// Build commands for a field drawn on the canvas. Text and checkbox fields
  /// are one command; a radio group is one command with one widget per option.
  public static func commands(
    kind: FormDetectedFieldKind, pageID: PDFObjectID, rect: [Double], baseName: String,
    label: String?, radioOptionCount: Int = 3
  ) -> [any PDFEditCommand] {
    switch kind {
    case .text:
      return [
        AddDetectedFormFieldCommand(
          pageID: pageID, baseName: baseName, rects: [rect],
          kind: .text(multiline: false, defaultValue: nil, fontSize: 12), label: label)
      ]
    case .checkbox:
      return [
        AddDetectedFormFieldCommand(
          pageID: pageID, baseName: baseName, rects: [rect], kind: .checkbox(checkedByDefault: false),
          label: label)
      ]
    case .radio:
      let count = max(2, radioOptionCount)
      let rects = radioRects(in: rect, count: count)
      let values = (1...count).map { "Option" + String($0) }
      return [
        AddDetectedFormFieldCommand(
          pageID: pageID, baseName: baseName, rects: rects,
          kind: .radioGroup(exportValues: values, selectedIndex: nil), label: label)
      ]
    }
  }
}
