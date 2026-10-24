import Foundation
import PDFCore

/// P24-001–P24-011: one AcroForm field with its inherited attributes, logical
/// values, and widget associations. Unknown or unsupported field types are
/// modeled, never executed.
public struct FormField: Sendable, Equatable {
  public enum Kind: String, Sendable {
    case text
    case button
    case choice
    case signature
    case unknown
  }

  /// P24-009: one choice option with its export and display values.
  public struct FormChoiceOption: Sendable, Equatable {
    public let export: String
    public let display: String

    public init(export: String, display: String) {
      self.export = export
      self.display = display
    }
  }

  /// The field dictionary's object identity, when it is indirect.
  public let fieldID: PDFObjectID?
  /// Fully qualified name (parents joined with dots).
  public let name: String
  public let kind: Kind
  public let flags: Int64
  public let value: PDFValue?
  public let defaultValue: PDFValue?
  public let widgets: [FormWidget]
  /// P24-009: choice options in document order.
  public let options: [FormChoiceOption]
  /// P24-009: selected option indexes (/I).
  public let selectedIndexes: [Int]

  public var isReadOnly: Bool { flags & 1 != 0 }
  public var isRequired: Bool { flags & 2 != 0 }
  /// P24-006: multiline text flag (bit 13).
  public var isMultiline: Bool { kind == .text && flags & 4096 != 0 }
  /// P24-010: push buttons are modeled but their actions never run.
  public var isPushButton: Bool { kind == .button && flags & 65536 != 0 }
  /// P24-008: radio groups use bit 16.
  public var isRadio: Bool { kind == .button && flags & 32768 != 0 }
  /// P24-009: combo boxes use bit 18.
  public var isCombo: Bool { kind == .choice && flags & 131072 != 0 }
  /// P24-015: multi-select lists use bit 22 and are not supported yet.
  public var isMultiSelect: Bool { kind == .choice && flags & 2_097_152 != 0 }

  public var selectedOption: FormChoiceOption? {
    guard let index = selectedIndexes.first, options.indices.contains(index) else {
      return nil
    }
    return options[index]
  }

  public var stringValue: String? {
    if case .string(let data)? = value {
      return AnnotationText.decode(data)
    }
    if case .array(let values)? = value {
      let strings = values.compactMap { item -> String? in
        guard case .string(let data) = item else { return nil }
        return AnnotationText.decode(data)
      }
      return strings.isEmpty ? nil : strings.joined(separator: ", ")
    }
    return nil
  }

  public var defaultStringValue: String? {
    guard case .string(let data)? = defaultValue else { return nil }
    return AnnotationText.decode(data)
  }

  /// Current button state: /V when present, otherwise the first widget's /AS.
  public var buttonState: PDFName? {
    if case .name(let name)? = value { return name }
    return widgets.first?.appearanceState
  }

  public var isChecked: Bool { (buttonState ?? PDFName("Off")) != PDFName("Off") }
}

/// P24-003: one widget of a field, with its page association and appearance
/// states.
public struct FormWidget: Sendable, Equatable {
  public let objectID: PDFObjectID?
  public let pageIndex: Int?
  public let rect: [Double]?
  /// Sorted /AP /N state names (P24-007: the widget's actual state names).
  public let appearanceStates: [PDFName]
  public let appearanceState: PDFName?
}

/// P24-001–P24-011: read the canonical AcroForm field tree with inherited
/// attributes and widget associations. Reading never executes field actions.
public enum FormInventory {
  public static func fields(in graph: PDFGraph, pageIDs: [PDFObjectID]) throws -> [FormField] {
    guard let acroForm = acroFormDictionary(in: graph),
      case .array(let roots)? = acroForm[PDFName("Fields")]
    else { return [] }
    let pages = widgetPages(in: graph, pageIDs: pageIDs)
    var results: [FormField] = []
    for root in roots {
      try walk(
        root, inherited: Inherited(), prefix: "", in: graph, pages: pages, into: &results)
    }
    return results
  }

  /// P24-004: widgets on pages whose parent chain never reaches a canonical
  /// field, reported separately instead of being duplicated as fields.
  public static func orphanedWidgets(
    in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) -> [FormWidget] {
    let canonical = Set(
      ((try? fields(in: graph, pageIDs: pageIDs)) ?? []).flatMap { field in
        field.widgets.compactMap(\.objectID)
      })
    var orphans: [FormWidget] = []
    for (objectID, pageIndex) in widgetPages(in: graph, pageIDs: pageIDs).sorted(by: {
      $0.key < $1.key
    }) {
      guard !canonical.contains(objectID) else { continue }
      guard case .dictionary(let widget)? = graph.objects[objectID] else { continue }
      orphans.append(makeWidget(widget, objectID: objectID, pageIndex: pageIndex, in: graph))
    }
    return orphans
  }

  struct Inherited {
    var ft: PDFName?
    var ff: Int64?
    var v: PDFValue?
    var dv: PDFValue?
    var da: PDFValue?
    var q: Int64?
  }

  static func acroFormDictionary(in graph: PDFGraph) -> [PDFName: PDFValue]? {
    guard case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[rootID]
    else { return nil }
    switch catalog[PDFName("AcroForm")] {
    case .dictionary(let dictionary)?:
      return dictionary
    case .reference(let id)?:
      if case .dictionary(let dictionary)? = graph.objects[id] { return dictionary }
      return nil
    default:
      return nil
    }
  }

  static func widgetPages(in graph: PDFGraph, pageIDs: [PDFObjectID]) -> [PDFObjectID: Int] {
    var map: [PDFObjectID: Int] = [:]
    for (index, pageID) in pageIDs.enumerated() {
      guard case .dictionary(let page)? = graph.objects[pageID] else { continue }
      let items: [PDFValue]
      switch page[PDFName("Annots")] {
      case .array(let array)?:
        items = array
      case .reference(let id)?:
        guard case .array(let array)? = graph.objects[id] else { continue }
        items = array
      default:
        continue
      }
      for item in items {
        guard case .reference(let id) = item,
          case .dictionary(let dictionary)? = graph.objects[id],
          dictionary[PDFName("Subtype")] == .name(PDFName("Widget"))
        else { continue }
        map[id] = index
      }
    }
    return map
  }

  static func resolvedDictionary(_ value: PDFValue, in graph: PDFGraph) -> [PDFName: PDFValue]? {
    switch value {
    case .dictionary(let dictionary):
      return dictionary
    case .reference(let id):
      if case .dictionary(let dictionary)? = graph.objects[id] { return dictionary }
      return nil
    default:
      return nil
    }
  }

  static func resolvedObjectID(_ value: PDFValue) -> PDFObjectID? {
    if case .reference(let id) = value { return id }
    return nil
  }

  static func walk(
    _ value: PDFValue, inherited: Inherited, prefix: String, in graph: PDFGraph,
    pages: [PDFObjectID: Int], into results: inout [FormField]
  ) throws {
    guard let field = resolvedDictionary(value, in: graph) else { return }
    let ft: PDFName?
    if case .name(let name)? = field[PDFName("FT")] { ft = name } else { ft = inherited.ft }
    let ff: Int64
    if case .integer(let raw)? = field[PDFName("Ff")] { ff = raw } else { ff = inherited.ff ?? 0 }
    let v = field[PDFName("V")] ?? inherited.v
    let dv = field[PDFName("DV")] ?? inherited.dv
    let da = field[PDFName("DA")] ?? inherited.da
    let q: Int64?
    if case .integer(let raw)? = field[PDFName("Q")] { q = raw } else { q = inherited.q }
    let partial = text(field[PDFName("T")]) ?? ""
    let name =
      prefix.isEmpty
      ? escapeName(partial) : (partial.isEmpty ? prefix : prefix + "." + escapeName(partial))

    let kids: [PDFValue]
    if case .array(let array)? = field[PDFName("Kids")] { kids = array } else { kids = [] }
    var childFields: [PDFValue] = []
    var widgetValues: [PDFValue] = []
    for kid in kids {
      guard let dictionary = resolvedDictionary(kid, in: graph) else { continue }
      // A kid is a child field when it has its own /T (merged field+widgets
      // do); pure widgets have no /T.
      if dictionary[PDFName("Subtype")] == .name(PDFName("Widget")),
        dictionary[PDFName("T")] == nil
      {
        widgetValues.append(kid)
      } else {
        childFields.append(kid)
      }
    }
    if !childFields.isEmpty {
      let childInherited = Inherited(ft: ft, ff: ff, v: v, dv: dv, da: da, q: q)
      for kid in childFields {
        try walk(
          kid, inherited: childInherited, prefix: name, in: graph, pages: pages, into: &results)
      }
      return
    }
    // Leaf field: its widgets are the kid widgets, or the field itself when
    // it is a merged field+widget.
    if field[PDFName("Subtype")] == .name(PDFName("Widget")) {
      widgetValues.append(value)
    }
    var widgets: [FormWidget] = []
    for widgetValue in widgetValues {
      guard let widget = resolvedDictionary(widgetValue, in: graph) else { continue }
      let objectID = resolvedObjectID(widgetValue)
      widgets.append(
        makeWidget(
          widget, objectID: objectID, pageIndex: objectID.flatMap { pages[$0] }, in: graph))
    }
    let kind: FormField.Kind
    switch ft {
    case PDFName("Tx"): kind = .text
    case PDFName("Btn"): kind = .button
    case PDFName("Ch"): kind = .choice
    case PDFName("Sig"): kind = .signature
    default: kind = .unknown
    }
    var options: [FormField.FormChoiceOption] = []
    if case .array(let rawOptions)? = field[PDFName("Opt")] {
      for option in rawOptions {
        switch option {
        case .string(let data):
          let text = AnnotationText.decode(data)
          options.append(FormField.FormChoiceOption(export: text, display: text))
        case .array(let pair):
          guard pair.count == 2, let export = text(pair[0]), let display = text(pair[1]) else {
            continue
          }
          options.append(FormField.FormChoiceOption(export: export, display: display))
        default:
          continue
        }
      }
    }
    var selectedIndexes: [Int] = []
    if case .array(let rawIndexes)? = field[PDFName("I")] {
      selectedIndexes = rawIndexes.compactMap { value in
        if case .integer(let raw) = value { return Int(raw) }
        return nil
      }
    }
    results.append(
      FormField(
        fieldID: resolvedObjectID(value), name: name, kind: kind, flags: ff, value: v,
        defaultValue: dv, widgets: widgets, options: options, selectedIndexes: selectedIndexes))
  }

  static func makeWidget(
    _ widget: [PDFName: PDFValue], objectID: PDFObjectID?, pageIndex: Int?, in graph: PDFGraph
  ) -> FormWidget {
    var states: [PDFName] = []
    if case .dictionary(let appearance)? = widget[PDFName("AP")],
      case .dictionary(let normal)? = appearance[PDFName("N")]
    {
      states = normal.keys.sorted()
    }
    var appearanceState: PDFName?
    if case .name(let name)? = widget[PDFName("AS")] { appearanceState = name }
    return FormWidget(
      objectID: objectID, pageIndex: pageIndex,
      rect: Annotation.numbers(widget[PDFName("Rect")], count: 4),
      appearanceStates: states, appearanceState: appearanceState)
  }

  static func text(_ value: PDFValue?) -> String? {
    guard case .string(let data)? = value else { return nil }
    return AnnotationText.decode(data)
  }

  /// P24-005: escape literal periods inside a partial name.
  static func escapeName(_ name: String) -> String {
    name.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: ".", with: "\\.")
  }
}
