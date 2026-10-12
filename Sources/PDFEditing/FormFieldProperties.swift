import Foundation
import PDFCore

/// P25-012/P25-013/P25-014/P25-015: declarative field properties. Formats and
/// calculation rules are stored in private keys (`/SPDFFormat`,
/// `/SPDFCalculate`) so nothing about them depends on document JavaScript;
/// existing `/AA` scripts are preserved untouched and never executed.
public enum AuthoredFieldFormat: Sendable, Equatable {
  case number(decimals: Int, prefix: String?, suffix: String?)
  case date(style: DateStyle)

  public enum DateStyle: String, Sendable, Equatable {
    case iso8601
    case short
    case long
  }
}

public enum AuthoredCalculation: Sendable, Equatable {
  case sum(fields: [String])

  public var fields: [String] {
    switch self {
    case .sum(let fields): return fields
    }
  }
}

/// P25-014: formatting and calculation evaluation that never runs scripts.
public enum FormFieldFormatting {
  public static func format(_ raw: String, rule: AuthoredFieldFormat) -> String? {
    switch rule {
    case .number(let decimals, let prefix, let suffix):
      let cleaned = raw.replacingOccurrences(of: ",", with: "")
        .trimmingCharacters(in: .whitespaces)
      guard let value = Double(cleaned) else { return nil }
      let formatter = NumberFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.numberStyle = .decimal
      formatter.minimumFractionDigits = max(0, min(decimals, 6))
      formatter.maximumFractionDigits = max(0, min(decimals, 6))
      formatter.groupingSeparator = ""
      formatter.usesGroupingSeparator = false
      guard let text = formatter.string(from: NSNumber(value: value)) else { return nil }
      return (prefix ?? "") + text + (suffix ?? "")
    case .date(let style):
      let parser = DateFormatter()
      parser.locale = Locale(identifier: "en_US_POSIX")
      parser.dateFormat = "yyyy-MM-dd"
      guard let date = parser.date(from: raw.trimmingCharacters(in: .whitespaces)) else {
        return nil
      }
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      switch style {
      case .iso8601: formatter.dateFormat = "yyyy-MM-dd"
      case .short: formatter.dateFormat = "d MMM yyyy"
      case .long: formatter.dateFormat = "MMMM d, yyyy"
      }
      return formatter.string(from: date)
    }
  }

  /// Numeric value of a stored field value, ignoring formatting prefixes.
  public static func numericValue(_ raw: String) -> Double? {
    let cleaned = raw.replacingOccurrences(of: ",", with: "")
      .trimmingCharacters(in: .whitespaces)
    if let value = Double(cleaned) { return value }
    // Tolerate a leading currency prefix or trailing suffix.
    let scalars = cleaned.drop { !$0.isNumber && $0 != "-" && $0 != "." }
    let digits = scalars.prefix { $0.isNumber || $0 == "." || $0 == "-" }
    return Double(digits)
  }

  static func decodedString(_ value: PDFValue?) -> String? {
    guard case .string(let data)? = value else { return nil }
    return AnnotationText.decode(data)
  }

  static func formatDictionary(_ rule: AuthoredFieldFormat) -> [PDFName: PDFValue] {
    switch rule {
    case .number(let decimals, let prefix, let suffix):
      var dictionary: [PDFName: PDFValue] = [
        PDFName("Kind"): .name(PDFName("Number")),
        PDFName("Decimals"): .integer(Int64(max(0, min(decimals, 6)))),
      ]
      if let prefix { dictionary[PDFName("Prefix")] = .string(AnnotationText.encode(prefix)) }
      if let suffix { dictionary[PDFName("Suffix")] = .string(AnnotationText.encode(suffix)) }
      return dictionary
    case .date(let style):
      return [
        PDFName("Kind"): .name(PDFName("Date")),
        PDFName("Style"): .name(PDFName(style.rawValue)),
      ]
    }
  }

  static func parseFormat(_ value: PDFValue?) -> AuthoredFieldFormat? {
    guard case .dictionary(let dictionary)? = value else { return nil }
    switch dictionary[PDFName("Kind")] {
    case .name(let name)? where name == PDFName("Number"):
      let decimals = (dictionary[PDFName("Decimals")].flatMap { raw -> Int? in
        if case .integer(let value) = raw { return Int(exactly: value) }
        return nil
      }) ?? 2
      return .number(
        decimals: decimals, prefix: decodedString(dictionary[PDFName("Prefix")]),
        suffix: decodedString(dictionary[PDFName("Suffix")]))
    case .name(let name)? where name == PDFName("Date"):
      var style: AuthoredFieldFormat.DateStyle = .iso8601
      if case .name(let styleName)? = dictionary[PDFName("Style")],
        let parsed = AuthoredFieldFormat.DateStyle(rawValue: String(decoding: styleName.bytes, as: UTF8.self))
      {
        style = parsed
      }
      return .date(style: style)
    default:
      return nil
    }
  }

  static func calculateDictionary(_ rule: AuthoredCalculation) -> [PDFName: PDFValue] {
    switch rule {
    case .sum(let fields):
      return [
        PDFName("Kind"): .name(PDFName("Sum")),
        PDFName("Fields"): .array(fields.map { .string(AnnotationText.encode($0)) }),
      ]
    }
  }

  static func parseCalculation(_ value: PDFValue?) -> AuthoredCalculation? {
    guard case .dictionary(let dictionary)? = value,
      case .name(let kind)? = dictionary[PDFName("Kind")], kind == PDFName("Sum"),
      case .array(let values)? = dictionary[PDFName("Fields")]
    else { return nil }
    let names = values.compactMap { value -> String? in
      guard case .string(let data) = value else { return nil }
      return AnnotationText.decode(data)
    }
    return .sum(fields: names)
  }
}

/// P25-007: the inspector's read model for one field.
public struct FormFieldProperties: Sendable, Equatable {
  public let name: String
  public let kind: FormField.Kind
  public let isRequired: Bool
  public let isReadOnly: Bool
  public let isMultiline: Bool
  public let isPassword: Bool
  public let maxLength: Int?
  public let alignment: Int?
  public let fontSize: Double?
  public let textColor: [Double]?
  public let borderColor: [Double]?
  public let backgroundColor: [Double]?
  public let borderWidth: Double?
  public let format: AuthoredFieldFormat?
  public let calculation: AuthoredCalculation?
}

public enum FormFieldPropertiesReader {
  public static func properties(
    forFieldNamed name: String, in graph: PDFGraph
  ) -> FormFieldProperties? {
    guard let pageIDs = try? PageTreeView(graph: graph).pages,
      let fields = try? FormInventory.fields(in: graph, pageIDs: pageIDs),
      let field = fields.first(where: { $0.name == name }),
      let fieldID = field.fieldID,
      case .dictionary(let dictionary)? = graph.objects[fieldID]
    else { return nil }
    var maxLength: Int?
    if case .integer(let raw)? = dictionary[PDFName("MaxLen")] { maxLength = Int(exactly: raw) }
    var alignment: Int?
    if case .integer(let raw)? = dictionary[PDFName("Q")] { alignment = Int(exactly: raw) }
    var fontSize: Double?
    var textColor: [Double]?
    if case .string(let data)? = dictionary[PDFName("DA")] {
      let parsed = SetFormTextCommand.parseDA(.string(data))
      fontSize = parsed.size
      textColor = parsed.color
    }
    var borderColor: [Double]?
    var backgroundColor: [Double]?
    if case .dictionary(let mk)? = dictionary[PDFName("MK")] {
      borderColor = numbers(mk[PDFName("BC")])
      backgroundColor = numbers(mk[PDFName("BG")])
    }
    var borderWidth: Double?
    if case .dictionary(let bs)? = dictionary[PDFName("BS")] {
      switch bs[PDFName("W")] {
      case .integer(let raw)?: borderWidth = Double(raw)
      case .real(let raw)?: borderWidth = raw
      default: break
      }
    }
    return FormFieldProperties(
      name: field.name, kind: field.kind, isRequired: field.isRequired,
      isReadOnly: field.isReadOnly, isMultiline: field.isMultiline,
      isPassword: field.flags & 8192 != 0, maxLength: maxLength, alignment: alignment,
      fontSize: fontSize, textColor: textColor, borderColor: borderColor,
      backgroundColor: backgroundColor, borderWidth: borderWidth,
      format: FormFieldFormatting.parseFormat(dictionary[PDFName("SPDFFormat")]),
      calculation: FormFieldFormatting.parseCalculation(dictionary[PDFName("SPDFCalculate")]))
  }

  static func numbers(_ value: PDFValue?) -> [Double]? {
    guard case .array(let values)? = value else { return nil }
    let numbers = values.compactMap { element -> Double? in
      switch element {
      case .integer(let number): return Double(number)
      case .real(let number): return number
      default: return nil
      }
    }
    return numbers.isEmpty ? nil : numbers
  }
}

/// P25-012: borders, colors, font size, text color, and alignment.
public struct SetFormFieldStyleCommand: PDFEditCommand, Equatable, Sendable {
  public let fieldName: String
  public let fontSize: Double?
  public let textColor: [Double]?
  public let alignment: Int?
  public let borderColor: [Double]?
  public let backgroundColor: [Double]?
  public let borderWidth: Double?

  public init(
    fieldName: String, fontSize: Double? = nil, textColor: [Double]? = nil,
    alignment: Int? = nil, borderColor: [Double]? = nil, backgroundColor: [Double]? = nil,
    borderWidth: Double? = nil
  ) {
    self.fieldName = fieldName
    self.fontSize = fontSize
    self.textColor = textColor
    self.alignment = alignment
    self.borderColor = borderColor
    self.backgroundColor = backgroundColor
    self.borderWidth = borderWidth
  }

  public var name: String { "Set Field Style" }

  public func validate(in graph: PDFGraph) throws {
    guard FormAuthoringSupport.findField(named: fieldName, in: graph) != nil else {
      throw PDFError(.malformed, "Form field is missing")
    }
    if let fontSize {
      guard (4...96).contains(fontSize) else {
        throw PDFError(.malformed, "Font size must be between 4 and 96")
      }
    }
    if let alignment {
      guard (0...2).contains(alignment) else {
        throw PDFError(.malformed, "Alignment is 0 (left), 1 (center), or 2 (right)")
      }
    }
    if let borderWidth {
      guard (0...8).contains(borderWidth) else {
        throw PDFError(.malformed, "Border width must be between 0 and 8")
      }
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    guard let fieldID = FormAuthoringSupport.findField(named: fieldName, in: graph),
      case .dictionary(var field)? = graph.objects[fieldID]
    else { throw PDFError(.malformed, "Form field is missing") }
    let context = try FormAuthoringSupport.ensureAcroForm(in: &graph)
    var acroForm = context.acroForm
    var nextNumber = FormAuthoringSupport.nextObjectID(in: graph).number

    if fontSize != nil || textColor != nil {
      var size = 12.0
      var color = [0.0, 0.0, 0.0]
      if case .string(let data)? = field[PDFName("DA")] {
        let parsed = SetFormTextCommand.parseDA(.string(data))
        size = parsed.size
        color = parsed.color
      }
      if let fontSize { size = fontSize }
      if let textColor, textColor.count == 3 { color = textColor }
      let components = Array(color.prefix(3))
      let colorOperator: String
      if components.count == 3, components[0] == components[1], components[1] == components[2] {
        colorOperator = "\(AnnotationSupport.number(components[0])) g"
      } else {
        colorOperator =
          components.map { AnnotationSupport.number($0) }.joined(separator: " ") + " rg"
      }
      let da = "/Helv \(AnnotationSupport.number(size)) Tf " + colorOperator
      field[PDFName("DA")] = .string(Data(da.utf8))
    }
    if let alignment { field[PDFName("Q")] = .integer(Int64(alignment)) }
    var mk: [PDFName: PDFValue] = [:]
    if case .dictionary(let existing)? = field[PDFName("MK")] { mk = existing }
    if let borderColor, borderColor.count == 3 {
      mk[PDFName("BC")] = .array(borderColor.map { PDFValue.real($0) })
    }
    if let backgroundColor, backgroundColor.count == 3 {
      mk[PDFName("BG")] = .array(backgroundColor.map { PDFValue.real($0) })
    }
    if !mk.isEmpty { field[PDFName("MK")] = .dictionary(mk) }
    if let borderWidth {
      var bs: [PDFName: PDFValue] = [:]
      if case .dictionary(let existing)? = field[PDFName("BS")] { bs = existing }
      bs[PDFName("W")] = .real(borderWidth)
      if bs[PDFName("S")] == nil { bs[PDFName("S")] = .name(PDFName("S")) }
      field[PDFName("BS")] = .dictionary(bs)
    }
    graph.objects[fieldID] = .dictionary(field)

    // Regenerate appearances so the style change is visible immediately.
    let kind = (try? FormInventory.fields(in: graph, pageIDs: PageTreeView(graph: graph).pages))
      .flatMap { $0.first { $0.name == fieldName } }?.kind
    if kind == .text || kind == .choice {
      if case .dictionary(let current)? = graph.objects[fieldID],
        let rect = Annotation.numbers(current[PDFName("Rect")], count: 4)
      {
        let da = SetFormTextCommand.parseDA(current[PDFName("DA")])
        let text = FormFieldFormatting.decodedString(current[PDFName("V")]) ?? ""
        let multiline = (kind == .text)
          && (FormFieldPropertiesReader.properties(forFieldNamed: fieldName, in: graph)?
            .isMultiline ?? false)
        let alignment = FormFieldPropertiesReader.properties(
          forFieldNamed: fieldName, in: graph)?.alignment ?? 0
        let appearance = SetFormTextCommand.textAppearance(
          text: text, rect: rect, multiline: multiline, da: da, fontID: context.helveticaID,
          alignment: alignment)
        nextNumber = try SetFormTextCommand.installAppearance(
          appearance, widgetID: fieldID, in: &graph, nextNumber: nextNumber)
      }
    } else if kind == .button {
      // Rebuild the state appearances from the updated /MK.
      nextNumber = try FormAuthoringSupport.regenerateButtonAppearances(
        widgetID: fieldID, in: &graph, nextNumber: nextNumber)
    }
    try FormAuthoringSupport.writeAcroForm(acroForm, catalogID: context.catalogID, in: &graph)
    _ = nextNumber
    return graph
  }
}

/// P25-013: allowed lengths for text fields, enforced by the fill command.
public struct SetFormFieldValidationCommand: PDFEditCommand, Equatable, Sendable {
  public let fieldName: String
  /// nil removes the limit.
  public let maxLength: Int?

  public init(fieldName: String, maxLength: Int?) {
    self.fieldName = fieldName
    self.maxLength = maxLength
  }

  public var name: String { "Set Field Validation" }

  public func validate(in graph: PDFGraph) throws {
    guard let pageIDs = try? PageTreeView(graph: graph).pages,
      let fields = try? FormInventory.fields(in: graph, pageIDs: pageIDs),
      let field = fields.first(where: { $0.name == fieldName })
    else { throw PDFError(.malformed, "Form field is missing") }
    guard field.kind == .text else {
      throw PDFError(.unsupported, "Length limits apply to text fields")
    }
    if let maxLength {
      guard (1...4096).contains(maxLength) else {
        throw PDFError(.malformed, "The maximum length must be between 1 and 4096")
      }
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    guard let fieldID = FormAuthoringSupport.findField(named: fieldName, in: graph),
      case .dictionary(var field)? = graph.objects[fieldID]
    else { throw PDFError(.malformed, "Form field is missing") }
    if let maxLength {
      field[PDFName("MaxLen")] = .integer(Int64(maxLength))
    } else {
      field.removeValue(forKey: PDFName("MaxLen"))
    }
    graph.objects[fieldID] = .dictionary(field)
    return graph
  }
}

/// P25-014: declarative number/date formatting for app-authored fields.
public struct SetFormFieldFormatCommand: PDFEditCommand, Equatable, Sendable {
  public let fieldName: String
  /// nil removes the rule.
  public let format: AuthoredFieldFormat?

  public init(fieldName: String, format: AuthoredFieldFormat?) {
    self.fieldName = fieldName
    self.format = format
  }

  public var name: String { "Set Field Format" }

  public func validate(in graph: PDFGraph) throws {
    guard let pageIDs = try? PageTreeView(graph: graph).pages,
      let fields = try? FormInventory.fields(in: graph, pageIDs: pageIDs),
      let field = fields.first(where: { $0.name == fieldName })
    else { throw PDFError(.malformed, "Form field is missing") }
    guard field.kind == .text else {
      throw PDFError(.unsupported, "Formats apply to text fields")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    guard let fieldID = FormAuthoringSupport.findField(named: fieldName, in: graph),
      case .dictionary(var field)? = graph.objects[fieldID]
    else { throw PDFError(.malformed, "Form field is missing") }
    if let format {
      field[PDFName("SPDFFormat")] = .dictionary(FormFieldFormatting.formatDictionary(format))
    } else {
      field.removeValue(forKey: PDFName("SPDFFormat"))
    }
    graph.objects[fieldID] = .dictionary(field)
    return graph
  }
}

/// P25-015: a bounded declarative calculation rule for app-authored fields.
public struct SetFormFieldCalculationCommand: PDFEditCommand, Equatable, Sendable {
  public let fieldName: String
  /// nil removes the rule.
  public let calculation: AuthoredCalculation?

  public init(fieldName: String, calculation: AuthoredCalculation?) {
    self.fieldName = fieldName
    self.calculation = calculation
  }

  public var name: String { "Set Field Calculation" }

  public func validate(in graph: PDFGraph) throws {
    guard let pageIDs = try? PageTreeView(graph: graph).pages,
      let fields = try? FormInventory.fields(in: graph, pageIDs: pageIDs),
      let field = fields.first(where: { $0.name == fieldName })
    else { throw PDFError(.malformed, "Form field is missing") }
    guard field.kind == .text else {
      throw PDFError(.unsupported, "Calculations apply to text fields")
    }
    if let calculation {
      let names = Set(fields.map(\.name))
      for reference in calculation.fields {
        guard names.contains(reference) else {
          throw PDFError(.malformed, "Calculation references the missing field \(reference)")
        }
        guard reference != fieldName else {
          throw PDFError(.malformed, "A calculation cannot reference its own field")
        }
      }
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    guard let fieldID = FormAuthoringSupport.findField(named: fieldName, in: graph),
      case .dictionary(var field)? = graph.objects[fieldID]
    else { throw PDFError(.malformed, "Form field is missing") }
    if let calculation {
      field[PDFName("SPDFCalculate")] = .dictionary(
        FormFieldFormatting.calculateDictionary(calculation))
    } else {
      field.removeValue(forKey: PDFName("SPDFCalculate"))
    }
    graph.objects[fieldID] = .dictionary(field)
    return graph
  }
}

/// P25-015: evaluate the declarative rules (one level, no scripts) and update
/// values and appearances.
public struct RecalculateFormCommand: PDFEditCommand, Equatable, Sendable {
  public init() {}

  public var name: String { "Recalculate Form" }

  public func validate(in graph: PDFGraph) throws {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID],
      catalog[PDFName("AcroForm")] != nil
    else { throw PDFError(.malformed, "The document has no form") }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let pageIDs = try PageTreeView(graph: graph).pages
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    let values: [String: String] = Dictionary(
      uniqueKeysWithValues: fields.compactMap { field in
        field.stringValue.map { (field.name, $0) }
      })
    var updates: [(name: String, text: String)] = []
    for field in fields {
      guard let fieldID = field.fieldID,
        case .dictionary(let dictionary)? = graph.objects[fieldID],
        let rule = FormFieldFormatting.parseCalculation(dictionary[PDFName("SPDFCalculate")])
      else { continue }
      guard !field.isReadOnly else { continue }
      switch rule {
      case .sum(let references):
        let total = references.reduce(0.0) { partial, name in
          guard let raw = values[name] else { return partial }
          return partial + (FormFieldFormatting.numericValue(raw) ?? 0)
        }
        // Pass the raw value; SetFormTextCommand applies any format rule.
        updates.append((field.name, String(format: "%g", total)))
      }
    }
    for update in updates {
      let command = SetFormTextCommand(fieldName: update.name, text: update.text)
      try command.validate(in: graph)
      graph = try command.apply(to: graph)
    }
    return graph
  }
}
