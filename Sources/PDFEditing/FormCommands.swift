import Foundation
import PDFCore

/// P24-017/P24-019: fill a text field, updating the canonical /V and every
/// widget appearance transactionally. Default values stay untouched and
/// /NeedAppearances is never used as proof of correctness (P24-020).
public struct SetFormTextCommand: PDFEditCommand, Equatable, Sendable {
  public let fieldName: String
  public let text: String

  public init(fieldName: String, text: String) {
    self.fieldName = fieldName
    self.text = text
  }

  public var name: String { "Fill Form Text" }

  public func validate(in graph: PDFGraph) throws {
    let context = try resolve(in: graph)
    guard AnnotationSupport.escapedLiteral(context.displayText) != nil else {
      throw PDFError(.unsupported, "Form text supports WinAnsi characters in this profile")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let context = try resolve(in: graph)
    var nextNumber = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    let fontID: PDFObjectID
    if let existing = AnnotationSupport.helveticaFontID(in: graph) {
      fontID = existing
    } else {
      fontID = PDFObjectID(nextNumber)
      nextNumber += 1
      graph.objects[fontID] = .dictionary(AnnotationSupport.helveticaFontDictionary())
    }
    guard let fieldID = context.field.fieldID,
      case .dictionary(var fieldDictionary)? = graph.objects[fieldID]
    else {
      throw PDFError(.malformed, "The field dictionary is missing")
    }
    fieldDictionary[PDFName("V")] = .string(AnnotationText.encode(context.displayText))
    graph.objects[fieldID] = .dictionary(fieldDictionary)

    for widget in context.field.widgets {
      guard let widgetID = widget.objectID, let rect = widget.rect else { continue }
      let appearance = Self.textAppearance(
        text: context.displayText, rect: rect, multiline: context.field.isMultiline,
        da: context.da, fontID: fontID)
      nextNumber = try Self.installAppearance(
        appearance, widgetID: widgetID, in: &graph, nextNumber: nextNumber)
    }
    graph.trailer[PDFName("Size")] = .integer(Int64(nextNumber))
    return graph
  }

  struct Context {
    let field: FormField
    let da: (size: Double, color: [Double])
    let displayText: String
  }

  func resolve(in graph: PDFGraph) throws -> Context {
    let pageIDs = try PageTreeView(graph: graph).pages
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    guard let field = fields.first(where: { $0.name == fieldName }) else {
      throw PDFError(.malformed, "Form field is missing")
    }
    guard field.kind == .text else {
      throw PDFError(.unsupported, "Only text fields can be filled with text")
    }
    guard !field.isReadOnly else {
      throw PDFError(.unsupported, "This form field is read-only")
    }
    guard let fieldID = field.fieldID else {
      throw PDFError(.unsupported, "Direct field dictionaries cannot be filled in this profile")
    }
    // P25-013: enforced maximum length.
    if case .dictionary(let dictionary)? = graph.objects[fieldID],
      case .integer(let raw)? = dictionary[PDFName("MaxLen")],
      let maxLength = Int(exactly: raw), text.count > maxLength
    {
      throw PDFError(
        .malformed, "The text exceeds the field's maximum length of \(maxLength) characters")
    }
    // P25-014: values must satisfy the declarative format rule when one is set.
    if case .dictionary(let dictionary)? = graph.objects[fieldID],
      let rule = FormFieldFormatting.parseFormat(dictionary[PDFName("SPDFFormat")]),
      FormFieldFormatting.format(text, rule: rule) == nil
    {
      throw PDFError(.malformed, "The value does not match the field's format")
    }
    let da = Self.parseDA(Self.daValue(for: field, in: graph))
    var displayText =
      field.isMultiline ? text : text.replacingOccurrences(of: "\n", with: " ")
    // P25-014: declarative formatting rules are applied to what is stored and
    // displayed; no document script is involved.
    if case .dictionary(let dictionary)? = graph.objects[fieldID],
      let rule = FormFieldFormatting.parseFormat(dictionary[PDFName("SPDFFormat")]),
      let formatted = FormFieldFormatting.format(text, rule: rule)
    {
      displayText = formatted
    }
    return Context(field: field, da: da, displayText: displayText)
  }

  /// The field's /DA, falling back to the AcroForm default.
  static func daValue(for field: FormField, in graph: PDFGraph) -> PDFValue? {
    if let fieldID = field.fieldID, case .dictionary(let dictionary)? = graph.objects[fieldID],
      let value = dictionary[PDFName("DA")]
    {
      return value
    }
    return FormInventory.acroFormDictionary(in: graph)?[PDFName("DA")]
  }

  static func parseDA(_ value: PDFValue?) -> (size: Double, color: [Double]) {
    guard case .string(let data)? = value else { return (12, [0, 0, 0]) }
    let tokens = String(decoding: data, as: UTF8.self)
      .split(whereSeparator: \.isWhitespace).map(String.init)
    var size = 12.0
    var color: [Double] = [0, 0, 0]
    for (index, token) in tokens.enumerated() {
      if token == "Tf", index >= 2, let value = Double(tokens[index - 1]) {
        size = value
      }
      if token == "rg", index >= 3 {
        let values = tokens[(index - 3)..<index].compactMap(Double.init)
        if values.count == 3 { color = values }
      }
      if token == "g", index >= 1, let value = Double(tokens[index - 1]) {
        color = [value, value, value]
      }
    }
    return (max(4, min(size, 96)), color)
  }

  static func textAppearance(
    text: String, rect: [Double], multiline: Bool, da: (size: Double, color: [Double]),
    fontID: PDFObjectID, alignment: Int = 0
  ) -> PDFStream {
    let width = rect[2] - rect[0]
    let height = rect[3] - rect[1]
    let size = min(da.size, max(4, height * 0.7))
    let leading = size * 1.2
    var content = "q\n"
    content += "BT\n/F1 \(AnnotationSupport.number(size)) Tf\n"
    content += "\(AnnotationSupport.number(da.color[0])) "
    content += "\(AnnotationSupport.number(da.color[1])) "
    content += "\(AnnotationSupport.number(da.color[2])) rg\n"
    for (index, line) in text.components(separatedBy: .newlines).enumerated() {
      guard let escaped = AnnotationSupport.escapedLiteral(line) else { continue }
      let y: Double
      if multiline {
        y = height - size - 2 - Double(index) * leading
      } else {
        y = (height - size) / 2 + size * 0.2
      }
      // P25-012: alignment (0 left, 1 center, 2 right) with an estimated
      // Helvetica width for the line.
      let estimatedWidth = Double(line.count) * size * 0.5
      let x: Double
      switch alignment {
      case 1: x = max(2, (width - estimatedWidth) / 2)
      case 2: x = max(2, width - estimatedWidth - 2)
      default: x = 2
      }
      content += "1 0 0 1 \(AnnotationSupport.number(x)) \(AnnotationSupport.number(y)) Tm \(escaped) Tj\n"
    }
    content += "ET\nQ\n"
    return AnnotationSupport.formAppearance(
      rect: [0, 0, width, height], content: content,
      resources: [PDFName("Font"): .dictionary([PDFName("F1"): .reference(fontID)])])
  }

  /// Replace an existing single-stream /AP /N in place, or add a new stream.
  static func installAppearance(
    _ appearance: PDFStream, widgetID: PDFObjectID, in graph: inout PDFGraph, nextNumber: Int
  ) throws -> Int {
    var nextNumber = nextNumber
    guard case .dictionary(var widget)? = graph.objects[widgetID] else { return nextNumber }
    var ap: [PDFName: PDFValue]
    if case .dictionary(let existing)? = widget[PDFName("AP")] { ap = existing } else { ap = [:] }
    if case .reference(let existingID)? = ap[PDFName("N")],
      case .stream? = graph.objects[existingID]
    {
      graph.objects[existingID] = .stream(appearance)
    } else {
      let newID = PDFObjectID(nextNumber)
      nextNumber += 1
      graph.objects[newID] = .stream(appearance)
      ap[PDFName("N")] = .reference(newID)
    }
    widget[PDFName("AP")] = .dictionary(ap)
    graph.objects[widgetID] = .dictionary(widget)
    return nextNumber
  }
}

/// P24-014/P24-018: set a checkbox or radio group to a logical state,
/// updating /V and every widget's /AS and generating any missing state
/// appearance with a standard check mark or dot.
public struct SetFormButtonStateCommand: PDFEditCommand, Equatable, Sendable {
  public let fieldName: String
  /// nil or "Off" clears the selection.
  public let state: PDFName?

  public init(fieldName: String, state: PDFName?) {
    self.fieldName = fieldName
    self.state = state
  }

  public var name: String { "Set Form Button" }

  public func validate(in graph: PDFGraph) throws {
    let field = try resolveField(in: graph)
    guard !field.isReadOnly else {
      throw PDFError(.unsupported, "This form field is read-only")
    }
    guard !field.isPushButton else {
      throw PDFError(.unsupported, "Push buttons have no selectable state")
    }
    let target = state ?? PDFName("Off")
    if target != PDFName("Off") {
      if field.isRadio {
        // Radio on-states are named per widget; the target must exist.
        let available = Set(field.widgets.flatMap(\.appearanceStates))
        guard available.contains(target) else {
          throw PDFError(.unsupported, "Unknown button state for this field")
        }
      } else {
        // A checkbox can be set to any on-state; a missing appearance is
        // generated with a standard check mark (P24-018).
        guard target.bytes.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else {
          throw PDFError(.malformed, "Checkbox state names must be printable ASCII")
        }
      }
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let field = try resolveField(in: graph)
    guard let fieldID = field.fieldID,
      case .dictionary(var fieldDictionary)? = graph.objects[fieldID]
    else {
      throw PDFError(.unsupported, "Direct field dictionaries cannot be filled in this profile")
    }
    let target = state ?? PDFName("Off")
    fieldDictionary[PDFName("V")] = .name(target)
    graph.objects[fieldID] = .dictionary(fieldDictionary)

    var nextNumber = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    for widget in field.widgets {
      guard let widgetID = widget.objectID,
        case .dictionary(var widgetDictionary)? = graph.objects[widgetID]
      else { continue }
      var widgetTarget = PDFName("Off")
      if target != PDFName("Off"), widget.appearanceStates.contains(target) {
        widgetTarget = target
      } else if target != PDFName("Off"), !field.isRadio {
        widgetTarget = target
      }
      nextNumber = try Self.ensureButtonAppearances(
        widgetID: widgetID, widget: widgetDictionary, target: widgetTarget, isRadio: field.isRadio,
        in: &graph, nextNumber: nextNumber)
      guard case .dictionary(var updated)? = graph.objects[widgetID] else { continue }
      updated[PDFName("AS")] = .name(widgetTarget)
      graph.objects[widgetID] = .dictionary(updated)
    }
    graph.trailer[PDFName("Size")] = .integer(Int64(nextNumber))
    return graph
  }

  func resolveField(in graph: PDFGraph) throws -> FormField {
    let pageIDs = try PageTreeView(graph: graph).pages
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    guard let field = fields.first(where: { $0.name == fieldName }) else {
      throw PDFError(.malformed, "Form field is missing")
    }
    guard field.kind == .button else {
      throw PDFError(.unsupported, "Only button fields have selectable states")
    }
    return field
  }

  static func ensureButtonAppearances(
    widgetID: PDFObjectID, widget: [PDFName: PDFValue], target: PDFName, isRadio: Bool,
    in graph: inout PDFGraph, nextNumber: Int
  ) throws -> Int {
    var nextNumber = nextNumber
    guard let rect = Annotation.numbers(widget[PDFName("Rect")], count: 4) else {
      throw PDFError(.malformed, "Button widget has no rectangle")
    }
    var ap: [PDFName: PDFValue]
    if case .dictionary(let existing)? = widget[PDFName("AP")] { ap = existing } else { ap = [:] }
    var normal: [PDFName: PDFValue]
    if case .dictionary(let states)? = ap[PDFName("N")] {
      normal = states
    } else if case .reference(let id)? = ap[PDFName("N")], case .stream? = graph.objects[id] {
      normal = [PDFName("Off"): .reference(id)]
    } else {
      normal = [:]
    }
    var mk: [PDFName: PDFValue] = [:]
    if case .dictionary(let dictionary)? = widget[PDFName("MK")] { mk = dictionary }
    for state in [PDFName("Off"), target] where normal[state] == nil {
      let stream = buttonAppearance(state: state, rect: rect, isRadio: isRadio, mk: mk)
      let id = PDFObjectID(nextNumber)
      nextNumber += 1
      graph.objects[id] = .stream(stream)
      normal[state] = .reference(id)
    }
    ap[PDFName("N")] = .dictionary(normal)
    guard case .dictionary(var updated)? = graph.objects[widgetID] else { return nextNumber }
    updated[PDFName("AP")] = .dictionary(ap)
    graph.objects[widgetID] = .dictionary(updated)
    return nextNumber
  }

  static func buttonAppearance(
    state: PDFName, rect: [Double], isRadio: Bool, mk: [PDFName: PDFValue]
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
        content +=
          "0 0 \(AnnotationSupport.number(width)) \(AnnotationSupport.number(height)) re f\n"
      }
    }
    if case .array(let border)? = mk[PDFName("BC")], border.count == 3 {
      let values = border.compactMap(Annotation.number)
      if values.count == 3 {
        content += "\(AnnotationSupport.number(values[0])) "
        content += "\(AnnotationSupport.number(values[1])) "
        content += "\(AnnotationSupport.number(values[2])) RG\n1 w\n"
        content += "0.5 0.5 \(AnnotationSupport.number(width - 1)) "
        content += "\(AnnotationSupport.number(height - 1)) re S\n"
      }
    }
    if state != PDFName("Off") {
      if isRadio {
        let radius = min(width, height) * 0.28
        content += "0 0 0 rg\n"
        content += AnnotationSupport.ellipsePath(
          cx: width / 2, cy: height / 2, rx: radius, ry: radius)
        content += "f\n"
      } else {
        let pad = min(width, height) * 0.2
        content += "0 0 0 RG\n"
        content += "\(AnnotationSupport.number(max(1, min(width, height) * 0.08))) w\n"
        content += "\(AnnotationSupport.number(pad)) "
        content += "\(AnnotationSupport.number(height * 0.5)) m "
        content += "\(AnnotationSupport.number(width * 0.42)) "
        content += "\(AnnotationSupport.number(pad)) l "
        content += "\(AnnotationSupport.number(width - pad)) "
        content += "\(AnnotationSupport.number(height - pad)) l S\n"
      }
    }
    content += "Q\n"
    return AnnotationSupport.formAppearance(
      rect: [0, 0, width, height], content: content)
  }
}

/// P24-009/P24-015: select a supported combo or single-select list option,
/// updating /V, /I, and every widget appearance transactionally.
public struct SetFormChoiceCommand: PDFEditCommand, Equatable, Sendable {
  public let fieldName: String
  /// Export value of the option to select.
  public let exportValue: String

  public init(fieldName: String, exportValue: String) {
    self.fieldName = fieldName
    self.exportValue = exportValue
  }

  public var name: String { "Set Form Choice" }

  public func validate(in graph: PDFGraph) throws {
    _ = try resolve(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let context = try resolve(in: graph)
    var nextNumber = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    let fontID: PDFObjectID
    if let existing = AnnotationSupport.helveticaFontID(in: graph) {
      fontID = existing
    } else {
      fontID = PDFObjectID(nextNumber)
      nextNumber += 1
      graph.objects[fontID] = .dictionary(AnnotationSupport.helveticaFontDictionary())
    }
    guard let fieldID = context.field.fieldID,
      case .dictionary(var fieldDictionary)? = graph.objects[fieldID]
    else {
      throw PDFError(.malformed, "The field dictionary is missing")
    }
    fieldDictionary[PDFName("V")] = .string(AnnotationText.encode(exportValue))
    fieldDictionary[PDFName("I")] = .array([.integer(Int64(context.index))])
    graph.objects[fieldID] = .dictionary(fieldDictionary)
    for widget in context.field.widgets {
      guard let widgetID = widget.objectID, let rect = widget.rect else { continue }
      let appearance = SetFormTextCommand.textAppearance(
        text: context.display, rect: rect, multiline: false, da: context.da, fontID: fontID)
      nextNumber = try SetFormTextCommand.installAppearance(
        appearance, widgetID: widgetID, in: &graph, nextNumber: nextNumber)
    }
    graph.trailer[PDFName("Size")] = .integer(Int64(nextNumber))
    return graph
  }

  struct Context {
    let field: FormField
    let index: Int
    let display: String
    let da: (size: Double, color: [Double])
  }

  func resolve(in graph: PDFGraph) throws -> Context {
    let pageIDs = try PageTreeView(graph: graph).pages
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    guard let field = fields.first(where: { $0.name == fieldName }) else {
      throw PDFError(.malformed, "Form field is missing")
    }
    guard field.kind == .choice else {
      throw PDFError(.unsupported, "Only choice fields can be selected")
    }
    guard !field.isReadOnly else {
      throw PDFError(.unsupported, "This form field is read-only")
    }
    guard !field.isMultiSelect else {
      throw PDFError(.unsupported, "Multi-select choice fields are not supported yet")
    }
    guard field.fieldID != nil else {
      throw PDFError(.unsupported, "Direct field dictionaries cannot be filled in this profile")
    }
    guard let index = field.options.firstIndex(where: { $0.export == exportValue }) else {
      throw PDFError(.malformed, "Unknown choice option for this field")
    }
    let da = SetFormTextCommand.parseDA(SetFormTextCommand.daValue(for: field, in: graph))
    return Context(field: field, index: index, display: field.options[index].display, da: da)
  }
}

/// P24-021: reset supported fields to their documented default values (/DV)
/// by reusing the same fill commands, so appearances stay consistent.
public struct ResetFormCommand: PDFEditCommand, Equatable, Sendable {
  public init() {}

  public var name: String { "Reset Form" }

  public func validate(in graph: PDFGraph) throws {
    let pageIDs = try PageTreeView(graph: graph).pages
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    let resettable = fields.contains { field in
      guard !field.isReadOnly else { return false }
      switch field.kind {
      case .text: return true
      case .choice: return !field.isMultiSelect
      case .button: return !field.isPushButton
      default: return false
      }
    }
    guard resettable else {
      throw PDFError(.malformed, "No resettable form fields are present")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let pageIDs = try PageTreeView(graph: graph).pages
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    for field in fields where !field.isReadOnly {
      switch field.kind {
      case .text:
        graph = try SetFormTextCommand(
          fieldName: field.name, text: field.defaultStringValue ?? ""
        ).apply(to: graph)
      case .choice:
        guard !field.isMultiSelect,
          let defaultValue = field.defaultStringValue,
          field.options.contains(where: { $0.export == defaultValue })
        else { continue }
        graph = try SetFormChoiceCommand(
          fieldName: field.name, exportValue: defaultValue
        ).apply(to: graph)
      case .button:
        guard !field.isPushButton else { continue }
        var state: PDFName?
        if case .name(let name)? = field.defaultValue, name != PDFName("Off") { state = name }
        graph = try SetFormButtonStateCommand(fieldName: field.name, state: state)
          .apply(to: graph)
      default:
        continue
      }
    }
    return graph
  }
}
