import Foundation
import PDFCore

/// P25-010: duplication with an explicit value-sharing policy. `sharedValue`
/// adds another widget to the same field (every widget always shows the same
/// value); `independentCopy` creates a separate field that starts from the
/// source's current value but evolves on its own.
public struct DuplicateFormFieldCommand: PDFEditCommand, Equatable, Sendable {
  public enum Sharing: Sendable, Equatable {
    case sharedValue
    case independentCopy
  }

  public let fieldName: String
  /// nil derives a unique name from the source (`Name` -> `Name2`).
  public let newName: String?
  public let pageID: PDFObjectID
  /// Offset applied to the source widget's rectangle.
  public let offset: [Double]
  public let sharing: Sharing

  public init(
    fieldName: String, newName: String? = nil, pageID: PDFObjectID, offset: [Double] = [0, -30],
    sharing: Sharing
  ) {
    self.fieldName = fieldName
    self.newName = newName
    self.pageID = pageID
    self.offset = offset
    self.sharing = sharing
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Duplicate Form Field" }

  public func validate(in graph: PDFGraph) throws {
    guard case .dictionary? = graph.objects[pageID] else {
      throw PDFError(.malformed, "The page is missing")
    }
    guard offset.count == 2 else {
      throw PDFError(.malformed, "The offset needs two values")
    }
    guard let fieldID = FormAuthoringSupport.findField(named: fieldName, in: graph),
      case .dictionary(let field)? = graph.objects[fieldID]
    else {
      throw PDFError(.malformed, "Form field is missing or has no widgets")
    }
    let hasKids: Bool = {
      if case .array(let widgets)? = field[PDFName("Kids")], !widgets.isEmpty { return true }
      return false
    }()
    guard hasKids || field[PDFName("Subtype")] == .name(PDFName("Widget")) else {
      throw PDFError(.malformed, "Form field is missing or has no widgets")
    }
    if sharing == .independentCopy {
      let name = newName ?? fieldName
      if newName != nil, FormAuthoringSupport.findField(named: name, in: graph) != nil {
        throw PDFError(.malformed, "A field with that name already exists")
      }
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    guard let fieldID = FormAuthoringSupport.findField(named: fieldName, in: graph),
      case .dictionary(let field)? = graph.objects[fieldID]
    else { throw PDFError(.malformed, "Form field is missing") }
    let context = try FormAuthoringSupport.ensureAcroForm(in: &graph)
    var acroForm = context.acroForm
    var nextNumber = FormAuthoringSupport.nextObjectID(in: graph).number

    // The source widget: a kid widget, or the merged field itself.
    var sourceWidget: [PDFName: PDFValue]
    var sourceWidgetID: PDFObjectID
    if case .array(let kids)? = field[PDFName("Kids")], case .reference(let kidID)? = kids.first,
      case .dictionary(let kid)? = graph.objects[kidID]
    {
      sourceWidget = kid
      sourceWidgetID = kidID
    } else {
      sourceWidget = field
      sourceWidgetID = fieldID
    }
    guard let rect = Annotation.numbers(sourceWidget[PDFName("Rect")], count: 4) else {
      throw PDFError(.malformed, "The source widget has no rectangle")
    }
    let newRect = [
      rect[0] + offset[0], rect[1] + offset[1], rect[2] + offset[0], rect[3] + offset[1],
    ]

    switch sharing {
    case .sharedValue:
      // Make sure the field has a widget list; split a merged field first.
      if field[PDFName("Subtype")] == .name(PDFName("Widget")) {
        var widgetKeys: [PDFName: PDFValue] = [
          PDFName("Type"): .name(PDFName("Annot")),
          PDFName("Subtype"): .name(PDFName("Widget")),
          PDFName("Rect"): .array(rect.map { PDFValue.real($0) }),
          PDFName("Parent"): .reference(fieldID),
          PDFName("P"): sourceWidget[PDFName("P")] ?? .reference(pageID),
          PDFName("F"): sourceWidget[PDFName("F")] ?? .integer(4),
        ]
        for key in [
          PDFName("MK"), PDFName("BS"), PDFName("AP"), PDFName("AS"), PDFName("DA"),
          PDFName("Border"), PDFName("Ff"),
        ] {
          if let value = sourceWidget[key] { widgetKeys[key] = value }
        }
        let originalWidgetID = PDFObjectID(nextNumber)
        nextNumber += 1
        graph.objects[originalWidgetID] = .dictionary(widgetKeys)
        var updatedField = field
        for key in [
          PDFName("Type"), PDFName("Subtype"), PDFName("Rect"), PDFName("P"), PDFName("MK"),
          PDFName("BS"), PDFName("AP"), PDFName("AS"), PDFName("Border"), PDFName("Ff"),
        ] {
          updatedField.removeValue(forKey: key)
        }
        updatedField[PDFName("Kids")] = .array([.reference(originalWidgetID)])
        graph.objects[fieldID] = .dictionary(updatedField)
        sourceWidget = widgetKeys
        sourceWidgetID = originalWidgetID
      }
      var newWidget = sourceWidget
      newWidget[PDFName("Rect")] = .array(newRect.map { PDFValue.real($0) })
      newWidget[PDFName("P")] = .reference(pageID)
      newWidget[PDFName("Parent")] = .reference(fieldID)
      newWidget.removeValue(forKey: PDFName("T"))
      let newWidgetID = PDFObjectID(nextNumber)
      nextNumber += 1
      graph.objects[newWidgetID] = .dictionary(newWidget)
      if case .dictionary(var updatedField)? = graph.objects[fieldID],
        case .array(var kids)? = updatedField[PDFName("Kids")]
      {
        kids.append(.reference(newWidgetID))
        updatedField[PDFName("Kids")] = .array(kids)
        graph.objects[fieldID] = .dictionary(updatedField)
      }
      nextNumber = try FormAuthoringSupport.refreshWidgetAppearances(
        widgetID: newWidgetID, in: &graph, nextNumber: nextNumber)
      try FormAuthoringSupport.addWidget(newWidgetID, pageID: pageID, in: &graph)
      _ = sourceWidgetID

    case .independentCopy:
      let baseName = newName ?? fieldName
      let uniqueName = try FormAuthoringSupport.uniqueName(baseName, in: graph)
      let newLeaf = uniqueName.split(separator: ".").last.map(String.init) ?? uniqueName
      let newFieldID = PDFObjectID(nextNumber)
      nextNumber += 1
      var newField = field
      // /T carries the leaf; the parent chain carries the prefix.
      newField[PDFName("T")] = .string(AnnotationText.encode(newLeaf))
      newField.removeValue(forKey: PDFName("Kids"))
      // An independent copy owns its value from here on.
      if let value = field[PDFName("V")] { newField[PDFName("V")] = value }
      graph.objects[newFieldID] = .dictionary(newField)
      // Clone widgets (or split a merged field).
      if case .array(let kids)? = field[PDFName("Kids")], !kids.isEmpty {
        var newKids: [PDFValue] = []
        for kid in kids {
          guard case .reference(let kidID) = kid,
            case .dictionary(let kid)? = graph.objects[kidID]
          else { continue }
          var widget = kid
          widget[PDFName("Parent")] = .reference(newFieldID)
          if let kidRect = Annotation.numbers(kid[PDFName("Rect")], count: 4) {
            widget[PDFName("Rect")] = .array(
              [
                kidRect[0] + offset[0], kidRect[1] + offset[1], kidRect[2] + offset[0],
                kidRect[3] + offset[1],
              ].map { PDFValue.real($0) })
          }
          widget[PDFName("P")] = .reference(pageID)
          let widgetID = PDFObjectID(nextNumber)
          nextNumber += 1
          graph.objects[widgetID] = .dictionary(widget)
          newKids.append(.reference(widgetID))
          nextNumber = try FormAuthoringSupport.refreshWidgetAppearances(
            widgetID: widgetID, in: &graph, nextNumber: nextNumber)
          try FormAuthoringSupport.addWidget(widgetID, pageID: pageID, in: &graph)
        }
        if case .dictionary(var stored)? = graph.objects[newFieldID] {
          stored[PDFName("Kids")] = .array(newKids)
          graph.objects[newFieldID] = .dictionary(stored)
        }
      } else {
        // A merged field+widget becomes a widget kid of the copy.
        var widget = sourceWidget
        widget[PDFName("Rect")] = .array(newRect.map { PDFValue.real($0) })
        widget[PDFName("Parent")] = .reference(newFieldID)
        widget[PDFName("P")] = .reference(pageID)
        widget.removeValue(forKey: PDFName("T"))
        let widgetID = PDFObjectID(nextNumber)
        nextNumber += 1
        graph.objects[widgetID] = .dictionary(widget)
        if case .dictionary(var stored)? = graph.objects[newFieldID] {
          for key in [
            PDFName("Type"), PDFName("Subtype"), PDFName("Rect"), PDFName("P"), PDFName("MK"),
            PDFName("BS"), PDFName("AP"), PDFName("AS"), PDFName("Border"), PDFName("Ff"),
          ] {
            stored.removeValue(forKey: key)
          }
          stored[PDFName("Kids")] = .array([.reference(widgetID)])
          graph.objects[newFieldID] = .dictionary(stored)
        }
        nextNumber = try FormAuthoringSupport.refreshWidgetAppearances(
          widgetID: widgetID, in: &graph, nextNumber: nextNumber)
        try FormAuthoringSupport.addWidget(widgetID, pageID: pageID, in: &graph)
      }
      try FormAuthoringSupport.attachLeaf(
        newFieldID, name: uniqueName, in: &graph, acroForm: &acroForm)
    }
    try FormAuthoringSupport.writeAcroForm(acroForm, catalogID: context.catalogID, in: &graph)
    _ = nextNumber
    return graph
  }
}

/// P25-018: field order and keyboard tab order. Reordering rewrites the
/// `/AcroForm /Fields` order and the widget annotation order in each page's
/// `/Annots` (the order readers use when a page does not request structure
/// order).
public struct ReorderFormFieldsCommand: PDFEditCommand, Equatable, Sendable {
  public let order: [String]

  public init(order: [String]) {
    self.order = order
  }

  public var name: String { "Reorder Form Fields" }

  public func validate(in graph: PDFGraph) throws {
    let pageIDs = try PageTreeView(graph: graph).pages
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    let current = Set(fields.map(\.name))
    guard Set(order).count == order.count else {
      throw PDFError(.malformed, "The order lists a field twice")
    }
    guard current == Set(order) else {
      throw PDFError(.malformed, "The order must list every field exactly once")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let pageIDs = try PageTreeView(graph: graph).pages
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    let rank: [String: Int] = Dictionary(
      uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
    // Reorder the tree by each entry's first leaf descendant so parent groups
    // follow the requested order too.
    func firstLeafName(of value: PDFValue, depth: Int = 0) -> String? {
      guard depth < 32, case .reference(let id) = value,
        case .dictionary(let dictionary)? = graph.objects[id]
      else { return nil }
      if let field = fields.first(where: { $0.fieldID == id }) { return field.name }
      if case .array(let kids)? = dictionary[PDFName("Kids")] {
        for kid in kids {
          if let name = firstLeafName(of: kid, depth: depth + 1) { return name }
        }
      }
      return nil
    }
    func reorderKids(of id: PDFObjectID, depth: Int = 0) {
      guard depth < 32, case .dictionary(var dictionary)? = graph.objects[id],
        case .array(let kids)? = dictionary[PDFName("Kids")]
      else { return }
      let sorted = kids.sorted { left, right in
        let leftRank = firstLeafName(of: left).flatMap { rank[$0] } ?? Int.max
        let rightRank = firstLeafName(of: right).flatMap { rank[$0] } ?? Int.max
        return leftRank < rightRank
      }
      dictionary[PDFName("Kids")] = .array(sorted)
      graph.objects[id] = .dictionary(dictionary)
      for kid in sorted {
        if case .reference(let kidID) = kid { reorderKids(of: kidID, depth: depth + 1) }
      }
    }
    if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID],
      case .dictionary(var acroForm)? = catalog[PDFName("AcroForm")],
      case .array(let roots)? = acroForm[PDFName("Fields")]
    {
      let sorted = roots.sorted { left, right in
        let leftRank = firstLeafName(of: left).flatMap { rank[$0] } ?? Int.max
        let rightRank = firstLeafName(of: right).flatMap { rank[$0] } ?? Int.max
        return leftRank < rightRank
      }
      acroForm[PDFName("Fields")] = .array(sorted)
      catalog[PDFName("AcroForm")] = .dictionary(acroForm)
      graph.objects[catalogID] = .dictionary(catalog)
      for root in sorted {
        if case .reference(let rootID) = root { reorderKids(of: rootID) }
      }
    }
    // Reorder widget annotations per page, preserving non-widget positions.
    for pageID in pageIDs {
      guard case .dictionary(var page)? = graph.objects[pageID],
        case .array(let annotations)? = page[PDFName("Annots")]
      else { continue }
      let widgetRanks: [PDFObjectID: Int] = Dictionary(
        uniqueKeysWithValues: fields.flatMap { field -> [(PDFObjectID, Int)] in
          guard let fieldRank = rank[field.name] else { return [] }
          return field.widgets.compactMap { widget in
            widget.objectID.map { ($0, fieldRank) }
          }
        })
      var widgetSlots: [Int] = []
      for (index, value) in annotations.enumerated() {
        if case .reference(let id) = value, widgetRanks[id] != nil { widgetSlots.append(index) }
      }
      guard widgetSlots.count >= 2 else { continue }
      let sortedWidgets = annotations.enumerated()
        .filter { widgetRanks[$0.element.referenceID ?? PDFObjectID(0)] != nil }
        .sorted { left, right in
          let leftRank = widgetRanks[left.element.referenceID ?? PDFObjectID(0)] ?? Int.max
          let rightRank = widgetRanks[right.element.referenceID ?? PDFObjectID(0)] ?? Int.max
          return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
        }
        .map(\.element)
      var updated = annotations
      for (slot, widget) in zip(widgetSlots, sortedWidgets) {
        updated[slot] = widget
      }
      page[PDFName("Annots")] = .array(updated)
      graph.objects[pageID] = .dictionary(page)
    }
    return graph
  }
}

private extension PDFValue {
  var referenceID: PDFObjectID? {
    if case .reference(let id) = self { return id }
    return nil
  }
}

/// P25-019: widget geometry alignment and distribution.
public enum FormWidgetEdge: String, Sendable, Equatable {
  case left
  case right
  case top
  case bottom
  case centerX
  case centerY
}

public struct AlignFormWidgetsCommand: PDFEditCommand, Equatable, Sendable {
  public let fields: [String]
  public let edge: FormWidgetEdge

  public init(fields: [String], edge: FormWidgetEdge) {
    self.fields = fields
    self.edge = edge
  }

  public var name: String { "Align Form Widgets" }

  public func validate(in graph: PDFGraph) throws {
    guard fields.count >= 2 else {
      throw PDFError(.malformed, "Alignment needs at least two fields")
    }
    try FormOrganizationSupport.validate(fields: fields, in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let rects = try FormOrganizationSupport.rects(fields: fields, in: graph)
    let target: Double
    switch edge {
    case .left: target = rects.map { $0.rect[0] }.min() ?? 0
    case .right: target = rects.map { $0.rect[2] }.max() ?? 0
    case .top: target = rects.map { $0.rect[3] }.max() ?? 0
    case .bottom: target = rects.map { $0.rect[1] }.min() ?? 0
    case .centerX: target = rects.map { ($0.rect[0] + $0.rect[2]) / 2 }.reduce(0, +) / Double(rects.count)
    case .centerY: target = rects.map { ($0.rect[1] + $0.rect[3]) / 2 }.reduce(0, +) / Double(rects.count)
    }
    for entry in rects {
      var rect = entry.rect
      switch edge {
      case .left: rect[2] = target + (rect[2] - rect[0]); rect[0] = target
      case .right: rect[0] = target - (rect[2] - rect[0]); rect[2] = target
      case .top: rect[1] = target - (rect[3] - rect[1]); rect[3] = target
      case .bottom: rect[3] = target + (rect[3] - rect[1]); rect[1] = target
      case .centerX:
        let half = (rect[2] - rect[0]) / 2
        rect[0] = target - half
        rect[2] = target + half
      case .centerY:
        let half = (rect[3] - rect[1]) / 2
        rect[1] = target - half
        rect[3] = target + half
      }
      FormOrganizationSupport.setRect(rect, widgetID: entry.widgetID, in: &graph)
    }
    return graph
  }
}

public struct DistributeFormWidgetsCommand: PDFEditCommand, Equatable, Sendable {
  public enum Axis: String, Sendable, Equatable {
    case horizontal
    case vertical
  }

  public let fields: [String]
  public let axis: Axis

  public init(fields: [String], axis: Axis) {
    self.fields = fields
    self.axis = axis
  }

  public var name: String { "Distribute Form Widgets" }

  public func validate(in graph: PDFGraph) throws {
    guard fields.count >= 3 else {
      throw PDFError(.malformed, "Distribution needs at least three fields")
    }
    try FormOrganizationSupport.validate(fields: fields, in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let rects = try FormOrganizationSupport.rects(fields: fields, in: graph)
    let sorted: [(rect: [Double], widgetID: PDFObjectID)]
    switch axis {
    case .horizontal: sorted = rects.sorted { $0.rect[0] < $1.rect[0] }
    case .vertical: sorted = rects.sorted { $0.rect[1] < $1.rect[1] }
    }
    guard let first = sorted.first, let last = sorted.last else { return graph }
    let span: Double
    switch axis {
    case .horizontal: span = (last.rect[0] + last.rect[2]) - first.rect[0]
    case .vertical: span = (last.rect[1] + last.rect[3]) - first.rect[1]
    }
    let step = span / Double(sorted.count - 1)
    var cursor = axis == .horizontal ? first.rect[0] : first.rect[1]
    for entry in sorted {
      var rect = entry.rect
      switch axis {
      case .horizontal:
        let width = rect[2] - rect[0]
        rect[0] = cursor
        rect[2] = cursor + width
        cursor += step
      case .vertical:
        let height = rect[3] - rect[1]
        rect[1] = cursor
        rect[3] = cursor + height
        cursor += step
      }
      FormOrganizationSupport.setRect(rect, widgetID: entry.widgetID, in: &graph)
    }
    return graph
  }
}

enum FormOrganizationSupport {
  static func validate(fields: [String], in graph: PDFGraph) throws {
    for name in fields {
      guard let fieldID = FormAuthoringSupport.findField(named: name, in: graph),
        case .dictionary(let field)? = graph.objects[fieldID]
      else { throw PDFError(.malformed, "Form field \(name) is missing") }
      let hasWidget =
        field[PDFName("Subtype")] == .name(PDFName("Widget"))
        || {
          if case .array(let kids)? = field[PDFName("Kids")] { return !kids.isEmpty }
          return false
        }()
      guard hasWidget else {
        throw PDFError(.malformed, "Form field \(name) has no widgets")
      }
    }
  }

  static func rects(
    fields: [String], in graph: PDFGraph
  ) throws -> [(rect: [Double], widgetID: PDFObjectID)] {
    var result: [(rect: [Double], widgetID: PDFObjectID)] = []
    for name in fields {
      guard let fieldID = FormAuthoringSupport.findField(named: name, in: graph),
        case .dictionary(let field)? = graph.objects[fieldID]
      else { throw PDFError(.malformed, "Form field \(name) is missing") }
      if case .array(let kids)? = field[PDFName("Kids")], case .reference(let kidID)? = kids.first,
        case .dictionary(let kid)? = graph.objects[kidID],
        let rect = Annotation.numbers(kid[PDFName("Rect")], count: 4)
      {
        result.append((rect, kidID))
      } else if let rect = Annotation.numbers(field[PDFName("Rect")], count: 4) {
        result.append((rect, fieldID))
      } else {
        throw PDFError(.malformed, "Form field \(name) has no rectangle")
      }
    }
    return result
  }

  static func setRect(_ rect: [Double], widgetID: PDFObjectID, in graph: inout PDFGraph) {
    guard case .dictionary(var widget)? = graph.objects[widgetID] else { return }
    widget[PDFName("Rect")] = .array(rect.map { PDFValue.real($0) })
    graph.objects[widgetID] = .dictionary(widget)
  }
}

/// P25-024: XFA presence is tracked separately from AcroForm authoring.
public enum FormXAFFlag {
  public static func hasXFA(in graph: PDFGraph) -> Bool {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID],
      case .dictionary(let acroForm)? = catalog[PDFName("AcroForm")]
    else { return false }
    return acroForm[PDFName("XFA")] != nil
  }

  public static let authoringWarning =
    "This document contains XFA form data. XFA is never authored or modified here; authoring affects the AcroForm tree only, and some readers may display the XFA instead of the AcroForm."
}
