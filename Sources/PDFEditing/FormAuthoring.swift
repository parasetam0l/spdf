import Foundation
import PDFCore

/// P25: app-authored AcroForm fields. Authoring builds canonical structures on
/// the same field tree the inventory reads: a catalog `/AcroForm` with
/// `/Fields` and `/DR`, indirect field/widget dictionaries, generated
/// appearances with a standard Helvetica resource, and page `/Annots` wiring.
enum FormAuthoringSupport {
  struct AcroFormContext {
    let catalogID: PDFObjectID
    let acroForm: [PDFName: PDFValue]
    let helveticaID: PDFObjectID
  }

  static func nextObjectID(in graph: PDFGraph) -> PDFObjectID {
    PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
  }

  static func ensureAcroForm(in graph: inout PDFGraph) throws -> AcroFormContext {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    else { throw PDFError(.malformed, "The catalog is missing") }
    var acroForm: [PDFName: PDFValue] = [:]
    if case .dictionary(let existing)? = catalog[PDFName("AcroForm")] {
      acroForm = existing
    } else if case .reference(let existingID)? = catalog[PDFName("AcroForm")],
      case .dictionary(let existing)? = graph.objects[existingID]
    {
      acroForm = existing
    }
    if acroForm[PDFName("Fields")] == nil {
      acroForm[PDFName("Fields")] = .array([])
    }
    var resources: [PDFName: PDFValue] = [:]
    if case .dictionary(let existing)? = acroForm[PDFName("DR")] {
      resources = existing
    }
    var fonts: [PDFName: PDFValue] = [:]
    if case .dictionary(let existing)? = resources[PDFName("Font")] {
      fonts = existing
    }
    let helveticaID: PDFObjectID
    if case .reference(let existingID)? = fonts[PDFName("Helv")],
      case .dictionary? = graph.objects[existingID]
    {
      helveticaID = existingID
    } else {
      helveticaID = nextObjectID(in: graph)
      graph.objects[helveticaID] = .dictionary([
        PDFName("Type"): .name(PDFName("Font")),
        PDFName("Subtype"): .name(PDFName("Type1")),
        PDFName("BaseFont"): .name(PDFName("Helvetica")),
        PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
      ])
      fonts[PDFName("Helv")] = .reference(helveticaID)
      resources[PDFName("Font")] = .dictionary(fonts)
      acroForm[PDFName("DR")] = .dictionary(resources)
    }
    // Authored fields always carry appearances; readers should not regenerate.
    if acroForm[PDFName("NeedAppearances")] == nil {
      acroForm[PDFName("NeedAppearances")] = .boolean(false)
    }
    catalog[PDFName("AcroForm")] = .dictionary(acroForm)
    graph.objects[catalogID] = .dictionary(catalog)
    return AcroFormContext(catalogID: catalogID, acroForm: acroForm, helveticaID: helveticaID)
  }

  static func writeAcroForm(
    _ acroForm: [PDFName: PDFValue], catalogID: PDFObjectID, in graph: inout PDFGraph
  ) throws {
    guard case .dictionary(var catalog)? = graph.objects[catalogID] else {
      throw PDFError(.malformed, "The catalog is missing")
    }
    catalog[PDFName("AcroForm")] = .dictionary(acroForm)
    graph.objects[catalogID] = .dictionary(catalog)
  }

  /// P25-008: a unique fully qualified name; a taken name gets a numeric
  /// suffix on its leaf component (`Details.Name` -> `Details.Name2`).
  static func uniqueName(_ base: String, in graph: PDFGraph) throws -> String {
    let pageIDs = try PageTreeView(graph: graph).pages
    let existing = Set((try? FormInventory.fields(in: graph, pageIDs: pageIDs))?.map(\.name) ?? [])
    guard existing.contains(base) else { return base }
    let components = base.split(separator: ".").map(String.init)
    let leaf = components.last ?? base
    let prefix = components.dropLast().joined(separator: ".")
    var counter = 2
    while true {
      let candidate = prefix.isEmpty ? "\(leaf)\(counter)" : "\(prefix).\(leaf)\(counter)"
      if !existing.contains(candidate) { return candidate }
      counter += 1
    }
  }

  /// P25-008: create non-terminal parents for dotted names.
  static func ensureParentChain(
    for name: String, in graph: inout PDFGraph, acroForm: inout [PDFName: PDFValue]
  ) throws -> String {
    let components = name.split(separator: ".").map(String.init)
    guard components.count > 1 else { return name }
    var fields: [PDFValue] = []
    if case .array(let existing)? = acroForm[PDFName("Fields")] { fields = existing }
    var parentID: PDFObjectID?
    for component in components.dropLast() {
      var found: PDFObjectID?
      if let parentID,
        case .dictionary(let parent)? = graph.objects[parentID],
        case .array(let kids)? = parent[PDFName("Kids")]
      {
        for kid in kids {
          if case .reference(let kidID) = kid,
            case .dictionary(let kidField)? = graph.objects[kidID],
            case .string(let data)? = kidField[PDFName("T")],
            AnnotationText.decode(data) == component
          {
            found = kidID
            break
          }
        }
      } else {
        for value in fields {
          if case .reference(let id) = value, case .dictionary(let field)? = graph.objects[id],
            case .string(let data)? = field[PDFName("T")],
            AnnotationText.decode(data) == component
          {
            found = id
            break
          }
        }
      }
      let id: PDFObjectID
      if let found {
        id = found
      } else {
        id = nextObjectID(in: graph)
        var parent: [PDFName: PDFValue] = [
          PDFName("T"): .string(AnnotationText.encode(component)),
          PDFName("Kids"): .array([]),
        ]
        if let parentID { parent[PDFName("Parent")] = .reference(parentID) }
        graph.objects[id] = .dictionary(parent)
        if let parentID {
          if case .dictionary(var parentField)? = graph.objects[parentID],
            case .array(var kids)? = parentField[PDFName("Kids")]
          {
            kids.append(.reference(id))
            parentField[PDFName("Kids")] = .array(kids)
            graph.objects[parentID] = .dictionary(parentField)
          }
        } else {
          fields.append(.reference(id))
        }
      }
      parentID = id
    }
    acroForm[PDFName("Fields")] = .array(fields)
    return components.last ?? name
  }

  /// Attach a leaf field under its parent chain (or `/Fields`). Parent lookup
  /// uses the caller's staged `/AcroForm`, which may not be written to the
  /// graph catalog yet.
  static func attachLeaf(
    _ fieldID: PDFObjectID, name: String, in graph: inout PDFGraph,
    acroForm: inout [PDFName: PDFValue]
  ) throws {
    let components = name.split(separator: ".").map(String.init)
    if components.count > 1 {
      let parentName = components.dropLast().joined(separator: ".")
      var stagedRoots: [PDFValue] = []
      if case .array(let roots)? = acroForm[PDFName("Fields")] { stagedRoots = roots }
      if let parentID = findFieldObject(named: parentName, in: graph, roots: stagedRoots),
        case .dictionary(var parent)? = graph.objects[parentID],
        case .array(var kids)? = parent[PDFName("Kids")]
      {
        kids.append(.reference(fieldID))
        parent[PDFName("Kids")] = .array(kids)
        graph.objects[parentID] = .dictionary(parent)
        if case .dictionary(var child)? = graph.objects[fieldID] {
          child[PDFName("Parent")] = .reference(parentID)
          graph.objects[fieldID] = .dictionary(child)
        }
        return
      }
    }
    if case .array(var fields)? = acroForm[PDFName("Fields")] {
      fields.append(.reference(fieldID))
      acroForm[PDFName("Fields")] = .array(fields)
    }
  }

  /// P25-008: raw-tree lookup that also finds non-terminal parent fields
  /// (the inventory only emits leaves). `roots` defaults to the catalog's
  /// `/AcroForm /Fields`.
  static func findFieldObject(
    named name: String, in graph: PDFGraph, roots: [PDFValue]? = nil
  ) -> PDFObjectID? {
    let components = name.split(separator: ".").map(String.init)
    guard !components.isEmpty else { return nil }
    let fields: [PDFValue]
    if let roots {
      fields = roots
    } else {
      guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
        case .dictionary(let catalog)? = graph.objects[catalogID],
        case .dictionary(let acroForm)? = catalog[PDFName("AcroForm")],
        case .array(let catalogFields)? = acroForm[PDFName("Fields")]
      else { return nil }
      fields = catalogFields
    }
    func match(_ values: [PDFValue], at index: Int) -> PDFObjectID? {
      for value in values {
        guard case .reference(let id) = value, case .dictionary(let field)? = graph.objects[id],
          case .string(let data)? = field[PDFName("T")],
          AnnotationText.decode(data) == components[index]
        else { continue }
        if index == components.count - 1 { return id }
        if case .array(let kids)? = field[PDFName("Kids")],
          let found = match(kids, at: index + 1)
        {
          return found
        }
      }
      return nil
    }
    return match(fields, at: 0)
  }

  static func findField(named name: String, in graph: PDFGraph) -> PDFObjectID? {
    guard let pageIDs = try? PageTreeView(graph: graph).pages,
      let fields = try? FormInventory.fields(in: graph, pageIDs: pageIDs)
    else { return nil }
    return fields.first { $0.name == name }?.fieldID
  }

  static func addWidget(
    _ widgetID: PDFObjectID, pageID: PDFObjectID, in graph: inout PDFGraph
  ) throws {
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "The page is missing")
    }
    var annotations: [PDFValue] = []
    if case .array(let existing)? = page[PDFName("Annots")] { annotations = existing }
    annotations.append(.reference(widgetID))
    page[PDFName("Annots")] = .array(annotations)
    graph.objects[pageID] = .dictionary(page)
  }

  static func removeWidget(
    _ widgetID: PDFObjectID, pageID: PDFObjectID, in graph: inout PDFGraph
  ) throws {
    guard case .dictionary(var page)? = graph.objects[pageID],
      case .array(let annotations)? = page[PDFName("Annots")]
    else { return }
    let filtered = annotations.filter { value in
      if case .reference(let id) = value, id == widgetID { return false }
      return true
    }
    page[PDFName("Annots")] = .array(filtered)
    graph.objects[pageID] = .dictionary(page)
  }

  /// P25-009/P25-021: drop a non-terminal parent that lost its last kid
  /// (no /FT, empty /Kids), walking up the chain.
  static func pruneEmptyParent(
    _ parentID: PDFObjectID, in graph: inout PDFGraph, acroForm: inout [PDFName: PDFValue]
  ) {
    guard case .dictionary(let parent)? = graph.objects[parentID] else { return }
    if parent[PDFName("FT")] != nil { return }
    if case .array(let kids)? = parent[PDFName("Kids")], !kids.isEmpty { return }
    if case .reference(let grandParentID)? = parent[PDFName("Parent")],
      case .dictionary(var grandParent)? = graph.objects[grandParentID],
      case .array(let kids)? = grandParent[PDFName("Kids")]
    {
      grandParent[PDFName("Kids")] = .array(
        kids.filter { value in
          if case .reference(let id) = value, id == parentID { return false }
          return true
        })
      graph.objects[grandParentID] = .dictionary(grandParent)
      pruneEmptyParent(grandParentID, in: &graph, acroForm: &acroForm)
    } else if case .array(let fields)? = acroForm[PDFName("Fields")] {
      acroForm[PDFName("Fields")] = .array(
        fields.filter { value in
          if case .reference(let id) = value, id == parentID { return false }
          return true
        })
    }
    graph.objects[parentID] = nil
  }

  static func widgetDictionary(
    rect: [Double], pageID: PDFObjectID, name: String?, fieldType: PDFName,
    flags: Int64, da: String?, defaultValue: PDFValue?, value: PDFValue?,
    background: [Double]?, border: [Double]?
  ) -> [PDFName: PDFValue] {
    var widget: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Annot")),
      PDFName("Subtype"): .name(PDFName("Widget")),
      PDFName("FT"): .name(fieldType),
      PDFName("Rect"): .array(rect.map { PDFValue.real($0) }),
      PDFName("P"): .reference(pageID),
      PDFName("F"): .integer(4),
      PDFName("Ff"): .integer(flags),
      PDFName("BS"): .dictionary([
        PDFName("W"): .integer(1), PDFName("S"): .name(PDFName("S")),
      ]),
    ]
    if let name { widget[PDFName("T")] = .string(AnnotationText.encode(name)) }
    var mk: [PDFName: PDFValue] = [:]
    if let background { mk[PDFName("BG")] = .array(background.map { PDFValue.real($0) }) }
    if let border { mk[PDFName("BC")] = .array(border.map { PDFValue.real($0) }) }
    if !mk.isEmpty { widget[PDFName("MK")] = .dictionary(mk) }
    if let da { widget[PDFName("DA")] = .string(Data(da.utf8)) }
    if let defaultValue { widget[PDFName("DV")] = defaultValue }
    if let value { widget[PDFName("V")] = value }
    return widget
  }

  /// A simple push-button appearance with a centered caption.
  static func pushButtonAppearance(
    caption: String, rect: [Double], mk: [PDFName: PDFValue]
  ) -> PDFStream {
    let width = rect[2] - rect[0]
    let height = rect[3] - rect[1]
    var content = "q\n"
    if case .array(let background)? = mk[PDFName("BG")], background.count == 3 {
      let values = background.compactMap(Annotation.number)
      if values.count == 3 {
        content += "\(AnnotationSupport.number(values[0])) "
        content += "\(AnnotationSupport.number(values[1])) "
        content += "\(AnnotationSupport.number(values[2])) rg\n"
        content += "0 0 \(AnnotationSupport.number(width)) \(AnnotationSupport.number(height)) re f\n"
      }
    }
    if case .array(let border)? = mk[PDFName("BC")], border.count == 3 {
      let values = border.compactMap(Annotation.number)
      if values.count == 3 {
        content += "\(AnnotationSupport.number(values[0])) "
        content += "\(AnnotationSupport.number(values[1])) "
        content += "\(AnnotationSupport.number(values[2])) RG\n1 w\n"
        content +=
          "0.5 0.5 \(AnnotationSupport.number(width - 1)) \(AnnotationSupport.number(height - 1)) re S\n"
      }
    }
    content += "BT\n/F1 11 Tf\n0 g\n"
    let size = 11.0
    let textWidth = Double(caption.count) * size * 0.5
    let x = max(2, (width - textWidth) / 2)
    let y = max(2, (height - size) / 2 + size * 0.2)
    if let escaped = AnnotationSupport.escapedLiteral(caption) {
      content += "1 0 0 1 \(AnnotationSupport.number(x)) \(AnnotationSupport.number(y)) Tm \(escaped) Tj\n"
    }
    content += "ET\nQ\n"
    return AnnotationSupport.formAppearance(
      rect: [0, 0, width, height], content: content)
  }

  /// P25-010/P25-019: rebuild one widget's normal appearance from its current
  /// field state (used by duplication and geometry edits).
  static func refreshWidgetAppearances(
    widgetID: PDFObjectID, in graph: inout PDFGraph, nextNumber: Int
  ) throws -> Int {
    var nextNumber = nextNumber
    guard case .dictionary(let widget)? = graph.objects[widgetID] else { return nextNumber }
    let fieldType: PDFName?
    if case .name(let name)? = widget[PDFName("FT")] {
      fieldType = name
    } else if case .reference(let parentID)? = widget[PDFName("Parent")],
      case .dictionary(let parent)? = graph.objects[parentID],
      case .name(let name)? = parent[PDFName("FT")]
    {
      fieldType = name
    } else {
      fieldType = nil
    }
    guard let rect = Annotation.numbers(widget[PDFName("Rect")], count: 4) else {
      return nextNumber
    }
    if let name = fieldType, name == PDFName("Tx") || name == PDFName("Ch") {
      let value = inheritedValue(PDFName("V"), of: widgetID, in: graph)
        .flatMap { raw -> String? in
          guard case .string(let data) = raw else { return nil }
          return AnnotationText.decode(data)
        } ?? ""
      let daValue = inheritedValue(PDFName("DA"), of: widgetID, in: graph)
      var da = (size: 12.0, color: [0.0, 0.0, 0.0])
      if let daValue { da = SetFormTextCommand.parseDA(daValue) }
      let fontID: PDFObjectID
      if let existing = AnnotationSupport.helveticaFontID(in: graph) {
        fontID = existing
      } else {
        fontID = PDFObjectID(nextNumber)
        nextNumber += 1
        graph.objects[fontID] = .dictionary(AnnotationSupport.helveticaFontDictionary())
      }
      let appearance = SetFormTextCommand.textAppearance(
        text: value, rect: rect, multiline: false, da: da, fontID: fontID)
      nextNumber = try SetFormTextCommand.installAppearance(
        appearance, widgetID: widgetID, in: &graph, nextNumber: nextNumber)
    } else if let name = fieldType, name == PDFName("Btn") {
      nextNumber = try regenerateButtonAppearances(
        widgetID: widgetID, in: &graph, nextNumber: nextNumber)
    }
    return nextNumber
  }

  /// The nearest value of a key along the widget's /Parent chain.
  static func inheritedValue(
    _ key: PDFName, of widgetID: PDFObjectID, in graph: PDFGraph
  ) -> PDFValue? {
    var current: PDFObjectID? = widgetID
    var depth = 0
    while let id = current, depth < 32 {
      guard case .dictionary(let dictionary)? = graph.objects[id] else { return nil }
      if let value = dictionary[key] { return value }
      if case .reference(let parentID)? = dictionary[PDFName("Parent")] {
        current = parentID
      } else {
        current = nil
      }
      depth += 1
    }
    return nil
  }

  /// P25-012/P25-027: rebuild a button widget's state appearances from its
  /// current /MK (colors and border).
  static func regenerateButtonAppearances(
    widgetID: PDFObjectID, in graph: inout PDFGraph, nextNumber: Int
  ) throws -> Int {
    var nextNumber = nextNumber
    guard case .dictionary(let widget)? = graph.objects[widgetID],
      let rect = Annotation.numbers(widget[PDFName("Rect")], count: 4)
    else { throw PDFError(.malformed, "Button widget has no rectangle") }
    var mk: [PDFName: PDFValue] = [:]
    if case .dictionary(let dictionary)? = widget[PDFName("MK")] { mk = dictionary }
    var flags: Int64 = 0
    if case .integer(let raw)? = widget[PDFName("Ff")] {
      flags = raw
    } else if case .reference(let parentID)? = widget[PDFName("Parent")],
      case .dictionary(let parent)? = graph.objects[parentID],
      case .integer(let raw)? = parent[PDFName("Ff")]
    {
      flags = raw
    }
    let isRadio = flags & 32768 != 0
    var ap: [PDFName: PDFValue] = [:]
    if case .dictionary(let existing)? = widget[PDFName("AP")] { ap = existing }
    var normal: [PDFName: PDFValue] = [:]
    if case .dictionary(let states)? = ap[PDFName("N")] { normal = states }
    var updated: [PDFName: PDFValue] = [:]
    for (state, value) in normal {
      let appearance = SetFormButtonStateCommand.buttonAppearance(
        state: state, rect: rect, isRadio: isRadio, mk: mk)
      if case .reference(let existingID) = value, case .stream? = graph.objects[existingID] {
        graph.objects[existingID] = .stream(appearance)
        updated[state] = value
      } else {
        let id = PDFObjectID(nextNumber)
        nextNumber += 1
        graph.objects[id] = .stream(appearance)
        updated[state] = .reference(id)
      }
    }
    if !updated.isEmpty {
      ap[PDFName("N")] = .dictionary(updated)
      if case .dictionary(var widgetUpdate)? = graph.objects[widgetID] {
        widgetUpdate[PDFName("AP")] = .dictionary(ap)
        graph.objects[widgetID] = .dictionary(widgetUpdate)
      }
    }
    return nextNumber
  }

  /// Walk a field subtree (field + kids) collecting object identities.
  static func subtreeIDs(of fieldID: PDFObjectID, in graph: PDFGraph) -> [PDFObjectID] {
    var result: [PDFObjectID] = []
    var visited: Set<PDFObjectID> = []
    func walk(_ id: PDFObjectID, depth: Int) {
      guard depth < 32, visited.insert(id).inserted else { return }
      result.append(id)
      guard case .dictionary(let field)? = graph.objects[id],
        case .array(let kids)? = field[PDFName("Kids")]
      else { return }
      for kid in kids {
        if case .reference(let kidID) = kid { walk(kidID, depth: depth + 1) }
      }
    }
    walk(fieldID, depth: 0)
    return result
  }
}

/// P25-001/P25-011/P25-020: place a new text field with flags and a default.
public struct AddTextFieldCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let rect: [Double]
  public let fieldName: String
  public let multiline: Bool
  public let required: Bool
  public let readOnly: Bool
  public let password: Bool
  public let defaultValue: String?
  public let fontSize: Double

  public init(
    pageID: PDFObjectID, rect: [Double], name: String, multiline: Bool = false,
    required: Bool = false, readOnly: Bool = false, password: Bool = false,
    defaultValue: String? = nil, fontSize: Double = 12
  ) {
    self.pageID = pageID
    self.rect = rect
    self.fieldName = name
    self.multiline = multiline
    self.required = required
    self.readOnly = readOnly
    self.password = password
    self.defaultValue = defaultValue
    self.fontSize = fontSize
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Add Text Field" }

  public func validate(in graph: PDFGraph) throws {
    guard case .dictionary? = graph.objects[pageID] else {
      throw PDFError(.malformed, "The page is missing")
    }
    guard rect.count == 4, rect[2] > rect[0], rect[3] > rect[1] else {
      throw PDFError(.malformed, "The field needs a non-empty rectangle")
    }
    guard !fieldName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PDFError(.malformed, "The field needs a name")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let context = try FormAuthoringSupport.ensureAcroForm(in: &graph)
    var acroForm = context.acroForm
    let uniqueFull = try FormAuthoringSupport.uniqueName(fieldName, in: graph)
    let uniqueLeaf = uniqueFull.split(separator: ".").last.map(String.init) ?? uniqueFull
    _ = try FormAuthoringSupport.ensureParentChain(
      for: uniqueFull, in: &graph, acroForm: &acroForm)
    var flags: Int64 = 0
    if readOnly { flags |= 1 }
    if required { flags |= 2 }
    if multiline { flags |= 4096 }
    if password { flags |= 8192 }
    let da = "/Helv \(AnnotationSupport.number(fontSize)) Tf 0 g"
    let defaultValue = self.defaultValue.map { PDFValue.string(AnnotationText.encode($0)) }
    var nextNumber = FormAuthoringSupport.nextObjectID(in: graph).number
    let fieldID = PDFObjectID(nextNumber)
    nextNumber += 1
    let widget = FormAuthoringSupport.widgetDictionary(
      rect: rect, pageID: pageID, name: uniqueLeaf, fieldType: PDFName("Tx"), flags: flags,
      da: da, defaultValue: defaultValue, value: defaultValue, background: [1, 1, 1],
      border: [0, 0, 0])
    graph.objects[fieldID] = .dictionary(widget)
    let appearance = SetFormTextCommand.textAppearance(
      text: self.defaultValue ?? "", rect: rect, multiline: multiline,
      da: (fontSize, [0, 0, 0]), fontID: context.helveticaID)
    nextNumber = try SetFormTextCommand.installAppearance(
      appearance, widgetID: fieldID, in: &graph, nextNumber: nextNumber)
    try FormAuthoringSupport.attachLeaf(
      fieldID, name: uniqueFull, in: &graph, acroForm: &acroForm)
    try FormAuthoringSupport.addWidget(fieldID, pageID: pageID, in: &graph)
    try FormAuthoringSupport.writeAcroForm(acroForm, catalogID: context.catalogID, in: &graph)
    _ = nextNumber
    return graph
  }
}

/// P25-002/P25-020: place a new checkbox with generated Off/on appearances.
public struct AddCheckboxCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let rect: [Double]
  public let fieldName: String
  public let checkedByDefault: Bool
  public let required: Bool
  public let readOnly: Bool

  public init(
    pageID: PDFObjectID, rect: [Double], name: String, checkedByDefault: Bool = false,
    required: Bool = false, readOnly: Bool = false
  ) {
    self.pageID = pageID
    self.rect = rect
    self.fieldName = name
    self.checkedByDefault = checkedByDefault
    self.required = required
    self.readOnly = readOnly
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Add Checkbox" }

  public func validate(in graph: PDFGraph) throws {
    guard case .dictionary? = graph.objects[pageID] else {
      throw PDFError(.malformed, "The page is missing")
    }
    guard rect.count == 4, rect[2] > rect[0], rect[3] > rect[1] else {
      throw PDFError(.malformed, "The checkbox needs a non-empty rectangle")
    }
    guard !fieldName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PDFError(.malformed, "The checkbox needs a name")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let context = try FormAuthoringSupport.ensureAcroForm(in: &graph)
    var acroForm = context.acroForm
    let uniqueFull = try FormAuthoringSupport.uniqueName(fieldName, in: graph)
    let uniqueLeaf = uniqueFull.split(separator: ".").last.map(String.init) ?? uniqueFull
    _ = try FormAuthoringSupport.ensureParentChain(
      for: uniqueFull, in: &graph, acroForm: &acroForm)
    var flags: Int64 = 0
    if readOnly { flags |= 1 }
    if required { flags |= 2 }
    var nextNumber = FormAuthoringSupport.nextObjectID(in: graph).number
    let fieldID = PDFObjectID(nextNumber)
    nextNumber += 1
    let value: PDFValue = checkedByDefault ? .name(PDFName("Yes")) : .name(PDFName("Off"))
    var widget = FormAuthoringSupport.widgetDictionary(
      rect: rect, pageID: pageID, name: uniqueLeaf, fieldType: PDFName("Btn"), flags: flags,
      da: nil, defaultValue: .name(PDFName("Off")), value: value, background: [1, 1, 1],
      border: [0, 0, 0])
    if checkedByDefault { widget[PDFName("AS")] = .name(PDFName("Yes")) }
    graph.objects[fieldID] = .dictionary(widget)
    nextNumber = try SetFormButtonStateCommand.ensureButtonAppearances(
      widgetID: fieldID, widget: widget, target: PDFName("Yes"), isRadio: false, in: &graph,
      nextNumber: nextNumber)
    try FormAuthoringSupport.attachLeaf(
      fieldID, name: uniqueFull, in: &graph, acroForm: &acroForm)
    try FormAuthoringSupport.addWidget(fieldID, pageID: pageID, in: &graph)
    try FormAuthoringSupport.writeAcroForm(acroForm, catalogID: context.catalogID, in: &graph)
    _ = nextNumber
    return graph
  }
}

/// P25-003: a radio group with one widget per rectangle and distinct export
/// values, sharing one parent field.
public struct AddRadioGroupCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let rects: [[Double]]
  public let fieldName: String
  public let exportValues: [String]
  public let selectedIndex: Int?
  public let required: Bool

  public init(
    pageID: PDFObjectID, rects: [[Double]], name: String, exportValues: [String],
    selectedIndex: Int? = nil, required: Bool = false
  ) {
    self.pageID = pageID
    self.rects = rects
    self.fieldName = name
    self.exportValues = exportValues
    self.selectedIndex = selectedIndex
    self.required = required
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Add Radio Group" }

  public func validate(in graph: PDFGraph) throws {
    guard case .dictionary? = graph.objects[pageID] else {
      throw PDFError(.malformed, "The page is missing")
    }
    guard !rects.isEmpty, rects.count == exportValues.count else {
      throw PDFError(.malformed, "Each radio widget needs an export value")
    }
    for rect in rects {
      guard rect.count == 4, rect[2] > rect[0], rect[3] > rect[1] else {
        throw PDFError(.malformed, "Radio widgets need non-empty rectangles")
      }
    }
    guard Set(exportValues).count == exportValues.count,
      !exportValues.contains("Off"),
      exportValues.allSatisfy({ !$0.isEmpty })
    else {
      throw PDFError(.malformed, "Radio export values must be unique, non-empty, and not Off")
    }
    if let selectedIndex {
      guard rects.indices.contains(selectedIndex) else {
        throw PDFError(.malformed, "The selected radio index is outside the group")
      }
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let context = try FormAuthoringSupport.ensureAcroForm(in: &graph)
    var acroForm = context.acroForm
    let uniqueFull = try FormAuthoringSupport.uniqueName(fieldName, in: graph)
    let uniqueLeaf = uniqueFull.split(separator: ".").last.map(String.init) ?? uniqueFull
    _ = try FormAuthoringSupport.ensureParentChain(
      for: uniqueFull, in: &graph, acroForm: &acroForm)
    var flags: Int64 = 32768
    if required { flags |= 2 }
    var nextNumber = FormAuthoringSupport.nextObjectID(in: graph).number
    let fieldID = PDFObjectID(nextNumber)
    nextNumber += 1
    let selectedValue: PDFName =
      selectedIndex.map { PDFName(exportValues[$0]) } ?? PDFName("Off")
    var field: [PDFName: PDFValue] = [
      PDFName("FT"): .name(PDFName("Btn")),
      PDFName("T"): .string(AnnotationText.encode(uniqueLeaf)),
      PDFName("Ff"): .integer(flags),
      PDFName("V"): .name(selectedValue),
      PDFName("Kids"): .array([]),
    ]
    var kids: [PDFValue] = []
    for (index, rect) in rects.enumerated() {
      let widgetID = PDFObjectID(nextNumber)
      nextNumber += 1
      let export = exportValues[index]
      var widget = FormAuthoringSupport.widgetDictionary(
        rect: rect, pageID: pageID, name: nil, fieldType: PDFName("Btn"), flags: flags,
        da: nil, defaultValue: nil, value: nil, background: [1, 1, 1], border: [0, 0, 0])
      widget[PDFName("Parent")] = .reference(fieldID)
      widget[PDFName("AS")] = .name(index == selectedIndex ? PDFName(export) : PDFName("Off"))
      graph.objects[widgetID] = .dictionary(widget)
      nextNumber = try SetFormButtonStateCommand.ensureButtonAppearances(
        widgetID: widgetID, widget: widget, target: PDFName(export), isRadio: true,
        in: &graph, nextNumber: nextNumber)
      kids.append(.reference(widgetID))
      try FormAuthoringSupport.addWidget(widgetID, pageID: pageID, in: &graph)
    }
    field[PDFName("Kids")] = .array(kids)
    graph.objects[fieldID] = .dictionary(field)
    try FormAuthoringSupport.attachLeaf(
      fieldID, name: uniqueFull, in: &graph, acroForm: &acroForm)
    try FormAuthoringSupport.writeAcroForm(acroForm, catalogID: context.catalogID, in: &graph)
    _ = nextNumber
    return graph
  }
}

/// P25-004: a list or combo choice field with authored options.
public struct AuthoredChoiceOption: Sendable, Equatable {
  public let exportValue: String
  public let displayValue: String

  public init(exportValue: String, displayValue: String? = nil) {
    self.exportValue = exportValue
    self.displayValue = displayValue ?? exportValue
  }
}

public struct AddChoiceFieldCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let rect: [Double]
  public let fieldName: String
  public let options: [AuthoredChoiceOption]
  public let combo: Bool
  public let defaultExportValue: String?
  public let required: Bool
  public let readOnly: Bool
  public let fontSize: Double

  public init(
    pageID: PDFObjectID, rect: [Double], name: String, options: [AuthoredChoiceOption],
    combo: Bool = true, defaultExportValue: String? = nil, required: Bool = false,
    readOnly: Bool = false, fontSize: Double = 12
  ) {
    self.pageID = pageID
    self.rect = rect
    self.fieldName = name
    self.options = options
    self.combo = combo
    self.defaultExportValue = defaultExportValue
    self.required = required
    self.readOnly = readOnly
    self.fontSize = fontSize
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Add Choice Field" }

  public func validate(in graph: PDFGraph) throws {
    guard case .dictionary? = graph.objects[pageID] else {
      throw PDFError(.malformed, "The page is missing")
    }
    guard rect.count == 4, rect[2] > rect[0], rect[3] > rect[1] else {
      throw PDFError(.malformed, "The choice field needs a non-empty rectangle")
    }
    guard !options.isEmpty,
      Set(options.map(\.exportValue)).count == options.count,
      options.allSatisfy({ !$0.exportValue.isEmpty })
    else {
      throw PDFError(.malformed, "Choice options must be non-empty and unique")
    }
    if let defaultExportValue {
      guard options.contains(where: { $0.exportValue == defaultExportValue }) else {
        throw PDFError(.malformed, "The default value is not one of the options")
      }
    }
    guard !fieldName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PDFError(.malformed, "The field needs a name")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let context = try FormAuthoringSupport.ensureAcroForm(in: &graph)
    var acroForm = context.acroForm
    let uniqueFull = try FormAuthoringSupport.uniqueName(fieldName, in: graph)
    let uniqueLeaf = uniqueFull.split(separator: ".").last.map(String.init) ?? uniqueFull
    _ = try FormAuthoringSupport.ensureParentChain(
      for: uniqueFull, in: &graph, acroForm: &acroForm)
    var flags: Int64 = 0
    if readOnly { flags |= 1 }
    if required { flags |= 2 }
    if combo { flags |= 131072 }
    let da = "/Helv \(AnnotationSupport.number(fontSize)) Tf 0 g"
    var optionsArray: [PDFValue] = []
    for option in options {
      if option.exportValue == option.displayValue {
        optionsArray.append(.string(AnnotationText.encode(option.exportValue)))
      } else {
        optionsArray.append(
          .array([
            .string(AnnotationText.encode(option.exportValue)),
            .string(AnnotationText.encode(option.displayValue)),
          ]))
      }
    }
    var nextNumber = FormAuthoringSupport.nextObjectID(in: graph).number
    let fieldID = PDFObjectID(nextNumber)
    nextNumber += 1
    var widget = FormAuthoringSupport.widgetDictionary(
      rect: rect, pageID: pageID, name: uniqueLeaf, fieldType: PDFName("Ch"), flags: flags,
      da: da, defaultValue: nil, value: nil, background: [1, 1, 1], border: [0, 0, 0])
    widget[PDFName("Opt")] = .array(optionsArray)
    if let defaultExportValue,
      let index = options.firstIndex(where: { $0.exportValue == defaultExportValue })
    {
      let option = options[index]
      widget[PDFName("V")] = .string(AnnotationText.encode(option.exportValue))
      widget[PDFName("DV")] = .string(AnnotationText.encode(option.exportValue))
      widget[PDFName("I")] = .array([.integer(Int64(index))])
    }
    graph.objects[fieldID] = .dictionary(widget)
    let display = defaultExportValue.map { value in
      options.first { $0.exportValue == value }?.displayValue ?? value
    }
    let appearance = SetFormTextCommand.textAppearance(
      text: display ?? "", rect: rect, multiline: false, da: (fontSize, [0, 0, 0]),
      fontID: context.helveticaID)
    nextNumber = try SetFormTextCommand.installAppearance(
      appearance, widgetID: fieldID, in: &graph, nextNumber: nextNumber)
    try FormAuthoringSupport.attachLeaf(
      fieldID, name: uniqueFull, in: &graph, acroForm: &acroForm)
    try FormAuthoringSupport.addWidget(fieldID, pageID: pageID, in: &graph)
    try FormAuthoringSupport.writeAcroForm(acroForm, catalogID: context.catalogID, in: &graph)
    _ = nextNumber
    return graph
  }
}

/// P25-005: a push button with an inert default or a safe URI action.
public struct AddPushButtonCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let rect: [Double]
  public let fieldName: String
  public let caption: String
  /// Only http, https, and mailto URIs are accepted; nil means inert.
  public let uri: String?

  public init(pageID: PDFObjectID, rect: [Double], name: String, caption: String, uri: String?) {
    self.pageID = pageID
    self.rect = rect
    self.fieldName = name
    self.caption = caption
    self.uri = uri
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Add Push Button" }

  public func validate(in graph: PDFGraph) throws {
    guard case .dictionary? = graph.objects[pageID] else {
      throw PDFError(.malformed, "The page is missing")
    }
    guard rect.count == 4, rect[2] > rect[0], rect[3] > rect[1] else {
      throw PDFError(.malformed, "The button needs a non-empty rectangle")
    }
    guard !fieldName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PDFError(.malformed, "The button needs a name")
    }
    if let uri {
      guard let safe = PDFHTMLEscape.safeURI(uri) else {
        throw PDFError(
          .unsupported, "Only http, https, and mailto actions are supported on authored buttons")
      }
      _ = safe
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let context = try FormAuthoringSupport.ensureAcroForm(in: &graph)
    var acroForm = context.acroForm
    let uniqueFull = try FormAuthoringSupport.uniqueName(fieldName, in: graph)
    let uniqueLeaf = uniqueFull.split(separator: ".").last.map(String.init) ?? uniqueFull
    _ = try FormAuthoringSupport.ensureParentChain(
      for: uniqueFull, in: &graph, acroForm: &acroForm)
    var nextNumber = FormAuthoringSupport.nextObjectID(in: graph).number
    let fieldID = PDFObjectID(nextNumber)
    nextNumber += 1
    var widget = FormAuthoringSupport.widgetDictionary(
      rect: rect, pageID: pageID, name: uniqueLeaf, fieldType: PDFName("Btn"), flags: 65536,
      da: nil, defaultValue: nil, value: nil, background: [0.9, 0.9, 0.9], border: [0, 0, 0])
    var mk: [PDFName: PDFValue] = [:]
    if case .dictionary(let existing)? = widget[PDFName("MK")] { mk = existing }
    mk[PDFName("CA")] = .string(AnnotationText.encode(caption))
    widget[PDFName("MK")] = .dictionary(mk)
    if let uri, let safe = PDFHTMLEscape.safeURI(uri) {
      widget[PDFName("A")] = .dictionary([
        PDFName("S"): .name(PDFName("URI")),
        PDFName("URI"): .string(AnnotationText.encode(safe)),
      ])
    }
    graph.objects[fieldID] = .dictionary(widget)
    let appearance = FormAuthoringSupport.pushButtonAppearance(caption: caption, rect: rect, mk: mk)
    nextNumber = try SetFormTextCommand.installAppearance(
      appearance, widgetID: fieldID, in: &graph, nextNumber: nextNumber)
    try FormAuthoringSupport.attachLeaf(
      fieldID, name: uniqueFull, in: &graph, acroForm: &acroForm)
    try FormAuthoringSupport.addWidget(fieldID, pageID: pageID, in: &graph)
    try FormAuthoringSupport.writeAcroForm(acroForm, catalogID: context.catalogID, in: &graph)
    _ = nextNumber
    return graph
  }
}

/// P25-006: an empty signature field; authoring never implies signing support.
public struct AddSignatureFieldCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let rect: [Double]
  public let fieldName: String

  public init(pageID: PDFObjectID, rect: [Double], name: String) {
    self.pageID = pageID
    self.rect = rect
    self.fieldName = name
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Add Signature Field" }

  public func validate(in graph: PDFGraph) throws {
    guard case .dictionary? = graph.objects[pageID] else {
      throw PDFError(.malformed, "The page is missing")
    }
    guard rect.count == 4, rect[2] > rect[0], rect[3] > rect[1] else {
      throw PDFError(.malformed, "The signature field needs a non-empty rectangle")
    }
    guard !fieldName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PDFError(.malformed, "The field needs a name")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let context = try FormAuthoringSupport.ensureAcroForm(in: &graph)
    var acroForm = context.acroForm
    let uniqueFull = try FormAuthoringSupport.uniqueName(fieldName, in: graph)
    let uniqueLeaf = uniqueFull.split(separator: ".").last.map(String.init) ?? uniqueFull
    _ = try FormAuthoringSupport.ensureParentChain(
      for: uniqueFull, in: &graph, acroForm: &acroForm)
    let fieldID = FormAuthoringSupport.nextObjectID(in: graph)
    let widget = FormAuthoringSupport.widgetDictionary(
      rect: rect, pageID: pageID, name: uniqueLeaf, fieldType: PDFName("Sig"), flags: 0,
      da: nil, defaultValue: nil, value: nil, background: nil, border: [0, 0, 0])
    graph.objects[fieldID] = .dictionary(widget)
    try FormAuthoringSupport.attachLeaf(
      fieldID, name: uniqueFull, in: &graph, acroForm: &acroForm)
    try FormAuthoringSupport.addWidget(fieldID, pageID: pageID, in: &graph)
    try FormAuthoringSupport.writeAcroForm(acroForm, catalogID: context.catalogID, in: &graph)
    return graph
  }
}

/// P25-011: set or clear the supported field flags on an existing field.
public struct SetFormFieldFlagsCommand: PDFEditCommand, Equatable, Sendable {
  public let fieldName: String
  public let required: Bool?
  public let readOnly: Bool?
  public let multiline: Bool?
  public let password: Bool?

  public init(
    fieldName: String, required: Bool? = nil, readOnly: Bool? = nil, multiline: Bool? = nil,
    password: Bool? = nil
  ) {
    self.fieldName = fieldName
    self.required = required
    self.readOnly = readOnly
    self.multiline = multiline
    self.password = password
  }

  public var name: String { "Set Field Flags" }

  public func validate(in graph: PDFGraph) throws {
    guard let pageIDs = try? PageTreeView(graph: graph).pages,
      let fields = try? FormInventory.fields(in: graph, pageIDs: pageIDs),
      fields.contains(where: { $0.name == fieldName })
    else { throw PDFError(.malformed, "Form field is missing") }
    if multiline != nil || password != nil {
      guard fields.first(where: { $0.name == fieldName })?.kind == .text else {
        throw PDFError(.unsupported, "Multiline and password flags apply to text fields")
      }
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    guard let fieldID = FormAuthoringSupport.findField(named: fieldName, in: graph),
      case .dictionary(var field)? = graph.objects[fieldID]
    else { throw PDFError(.malformed, "Form field is missing") }
    var flags: Int64 = 0
    if case .integer(let raw)? = field[PDFName("Ff")] { flags = raw }
    func update(_ value: Bool?, _ bit: Int64) {
      guard let value else { return }
      if value { flags |= bit } else { flags &= ~bit }
    }
    update(readOnly, 1)
    update(required, 2)
    update(multiline, 4096)
    update(password, 8192)
    field[PDFName("Ff")] = .integer(flags)
    graph.objects[fieldID] = .dictionary(field)
    return graph
  }
}

/// P25-009: rename a field (with its hierarchical parent chain) and update
/// child name prefixes.
public struct RenameFormFieldCommand: PDFEditCommand, Equatable, Sendable {
  public let fieldName: String
  public let newName: String

  public init(fieldName: String, newName: String) {
    self.fieldName = fieldName
    self.newName = newName
  }

  public var name: String { "Rename Form Field" }

  public func validate(in graph: PDFGraph) throws {
    guard FormAuthoringSupport.findField(named: fieldName, in: graph) != nil else {
      throw PDFError(.malformed, "Form field is missing")
    }
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw PDFError(.malformed, "The new name must not be empty")
    }
    guard trimmed != fieldName else {
      throw PDFError(.malformed, "The new name is the current name")
    }
    if let pageIDs = try? PageTreeView(graph: graph).pages,
      let fields = try? FormInventory.fields(in: graph, pageIDs: pageIDs)
    {
      guard !fields.contains(where: { $0.name == trimmed }) else {
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
    let oldLeaf = fieldName.split(separator: ".").last.map(String.init) ?? fieldName
    let newLeaf = newName.split(separator: ".").last.map(String.init) ?? newName
    // Detach from the old parent chain (pruning it when it empties).
    if fieldName.contains(".") {
      let parentName = fieldName.split(separator: ".").dropLast().joined(separator: ".")
      if let parentID = FormAuthoringSupport.findFieldObject(named: parentName, in: graph),
        case .dictionary(var parent)? = graph.objects[parentID],
        case .array(let kids)? = parent[PDFName("Kids")]
      {
        parent[PDFName("Kids")] = .array(
          kids.filter { value in
            if case .reference(let id) = value, id == fieldID { return false }
            return true
          })
        graph.objects[parentID] = .dictionary(parent)
        FormAuthoringSupport.pruneEmptyParent(parentID, in: &graph, acroForm: &acroForm)
      }
    } else if case .array(let fields)? = acroForm[PDFName("Fields")] {
      acroForm[PDFName("Fields")] = .array(
        fields.filter { value in
          if case .reference(let id) = value, id == fieldID { return false }
          return true
        })
    }
    // Update the leaf name and any hierarchical child prefixes.
    if case .dictionary(var updated)? = graph.objects[fieldID] {
      updated[PDFName("T")] = .string(AnnotationText.encode(newLeaf))
      graph.objects[fieldID] = .dictionary(updated)
    }
    let children = FormAuthoringSupport.subtreeIDs(of: fieldID, in: graph).dropFirst()
    for childID in children {
      guard case .dictionary(var child)? = graph.objects[childID],
        case .string(let data)? = child[PDFName("T")]
      else { continue }
      let name = AnnotationText.decode(data)
      if name.hasPrefix(oldLeaf + ".") {
        child[PDFName("T")] = .string(
          AnnotationText.encode(newLeaf + String(name.dropFirst(oldLeaf.count))))
        graph.objects[childID] = .dictionary(child)
      }
    }
    // Re-attach under the new parent chain.
    _ = try FormAuthoringSupport.ensureParentChain(
      for: newName, in: &graph, acroForm: &acroForm)
    try FormAuthoringSupport.attachLeaf(
      fieldID, name: newName, in: &graph, acroForm: &acroForm)
    try FormAuthoringSupport.writeAcroForm(acroForm, catalogID: context.catalogID, in: &graph)
    return graph
  }
}

/// P25-021: delete a field subtree, its widgets' page annotations, and the
/// objects that become unreferenced.
public struct RemoveFormFieldCommand: PDFEditCommand, Equatable, Sendable {
  public let fieldName: String

  public init(fieldName: String) {
    self.fieldName = fieldName
  }

  public var name: String { "Remove Form Field" }

  public func validate(in graph: PDFGraph) throws {
    guard FormAuthoringSupport.findField(named: fieldName, in: graph) != nil else {
      throw PDFError(.malformed, "Form field is missing")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    guard let fieldID = FormAuthoringSupport.findField(named: fieldName, in: graph) else {
      throw PDFError(.malformed, "Form field is missing")
    }
    let context = try FormAuthoringSupport.ensureAcroForm(in: &graph)
    var acroForm = context.acroForm
    let removedIDs = FormAuthoringSupport.subtreeIDs(of: fieldID, in: graph)
    // Detach from the parent chain or /Fields.
    if fieldName.contains(".") {
      let parentName = fieldName.split(separator: ".").dropLast().joined(separator: ".")
      if let parentID = FormAuthoringSupport.findFieldObject(named: parentName, in: graph),
        case .dictionary(var parent)? = graph.objects[parentID],
        case .array(let kids)? = parent[PDFName("Kids")]
      {
        parent[PDFName("Kids")] = .array(
          kids.filter { value in
            if case .reference(let id) = value, id == fieldID { return false }
            return true
          })
        graph.objects[parentID] = .dictionary(parent)
        FormAuthoringSupport.pruneEmptyParent(parentID, in: &graph, acroForm: &acroForm)
      }
    } else if case .array(let fields)? = acroForm[PDFName("Fields")] {
      acroForm[PDFName("Fields")] = .array(
        fields.filter { value in
          if case .reference(let id) = value, id == fieldID { return false }
          return true
        })
    }
    if case .reference(let catalogID)? = graph.trailer[PDFName("Root")] {
      try FormAuthoringSupport.writeAcroForm(
        acroForm, catalogID: catalogID, in: &graph)
    }
    // Remove widget annotations from their pages.
    if let pageIDs = try? PageTreeView(graph: graph).pages {
      for widgetID in removedIDs {
        guard case .dictionary(let widget)? = graph.objects[widgetID],
          case .reference(let pageID)? = widget[PDFName("P")],
          pageIDs.contains(pageID)
        else { continue }
        try FormAuthoringSupport.removeWidget(widgetID, pageID: pageID, in: &graph)
      }
    }
    // Delete unreferenced objects (fields, widgets, appearances).
    let referenced = AttachmentTree.references(in: graph, excluding: Set(removedIDs))
    for id in removedIDs where !referenced.contains(id) {
      graph.objects[id] = nil
    }
    return graph
  }
}
