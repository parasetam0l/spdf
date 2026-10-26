import Foundation
import PDFCore

/// AUT-07: a portable, declarative export recipe. Recipes are plain JSON data:
/// they never contain code, never fetch anything and are never executed by the
/// validator. Validation checks the declared schema, migrates supported older
/// versions, and explains every incompatible operation before any processing.
public struct RecipeDocument: Sendable, Equatable, Codable {
  public static let currentVersion = 1
  /// Versions this build can read. Older versions are migrated; newer versions
  /// are refused with an explanation instead of being guessed at.
  public static let supportedReadVersions: Set<Int> = [0, 1]

  public let version: Int
  public let name: String
  public let appVersion: String?
  public let operations: [RecipeOperation]
  public let metadata: [String: String]

  public init(
    version: Int = RecipeDocument.currentVersion, name: String, appVersion: String? = nil,
    operations: [RecipeOperation], metadata: [String: String] = [:]
  ) {
    self.version = version
    self.name = name
    self.appVersion = appVersion
    self.operations = operations
    self.metadata = metadata
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion)
    operations = try container.decodeIfPresent([RecipeOperation].self, forKey: .operations) ?? []
    metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
  }
}

/// One declarative operation. The type names a known app operation; settings
/// carry only schema-declared scalar/array values.
public struct RecipeOperation: Sendable, Equatable, Codable {
  public let type: String
  public let label: String?
  public let settings: [String: RecipeValue]

  public init(type: String, label: String? = nil, settings: [String: RecipeValue] = [:]) {
    self.type = type
    self.label = label
    self.settings = settings
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
    label = try container.decodeIfPresent(String.self, forKey: .label)
    settings =
      try container.decodeIfPresent([String: RecipeValue].self, forKey: .settings) ?? [:]
  }
}

/// AUT-07: JSON-safe setting value. Only data is representable; no expressions,
/// references or executable payloads.
public enum RecipeValue: Sendable, Equatable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case list([RecipeValue])
  case object([String: RecipeValue])

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var numberValue: Double? {
    if case .number(let value) = self { return value }
    return nil
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var listValue: [RecipeValue]? {
    if case .list(let value) = self { return value }
    return nil
  }

  public var objectValue: [String: RecipeValue]? {
    if case .object(let value) = self { return value }
    return nil
  }
}

extension RecipeValue: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { throw RecipeDecodingError.nullValue }
    if let value = try? container.decode(Bool.self) {
      self = .bool(value)
      return
    }
    if let value = try? container.decode(Double.self) {
      self = .number(value)
      return
    }
    if let value = try? container.decode(String.self) {
      self = .string(value)
      return
    }
    if let value = try? container.decode([RecipeValue].self) {
      self = .list(value)
      return
    }
    if let value = try? container.decode([String: RecipeValue].self) {
      self = .object(value)
      return
    }
    throw RecipeDecodingError.unsupportedValue
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .list(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

public enum RecipeDecodingError: Error, Equatable {
  case nullValue
  case unsupportedValue
}

public enum RecipeIssueSeverity: String, Sendable, Equatable {
  case warning
  case error
}

public struct RecipeIssue: Sendable, Equatable {
  public let severity: RecipeIssueSeverity
  public let code: String
  public let message: String
  public let operationIndex: Int?

  public init(
    severity: RecipeIssueSeverity, code: String, message: String,
    operationIndex: Int? = nil
  ) {
    self.severity = severity
    self.code = code
    self.message = message
    self.operationIndex = operationIndex
  }
}

/// AUT-07: the validated import result. A recipe is accepted only when every
/// operation and setting is declared and no incompatible/unknown item remains.
public struct RecipeValidation: Sendable, Equatable {
  public let recipe: RecipeDocument?
  public let issues: [RecipeIssue]
  public let migratedFromVersion: Int?

  public var isAccepted: Bool {
    recipe != nil && !issues.contains { $0.severity == .error }
  }

  public var errors: [RecipeIssue] { issues.filter { $0.severity == .error } }
  public var warnings: [RecipeIssue] { issues.filter { $0.severity == .warning } }

  public init(
    recipe: RecipeDocument?, issues: [RecipeIssue], migratedFromVersion: Int? = nil
  ) {
    self.recipe = recipe
    self.issues = issues
    self.migratedFromVersion = migratedFromVersion
  }
}

/// AUT-07: declared parameter rule for one operation setting.
public struct RecipeParameterRule: Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable {
    case string
    case number
    case boolean
    case stringList
  }

  public let kind: Kind
  public let required: Bool
  public let allowedValues: [String]
  public let minimum: Double?
  public let maximum: Double?

  public init(
    kind: Kind, required: Bool = false, allowedValues: [String] = [],
    minimum: Double? = nil, maximum: Double? = nil
  ) {
    self.kind = kind
    self.required = required
    self.allowedValues = allowedValues
    self.minimum = minimum
    self.maximum = maximum
  }
}

public struct RecipeOperationSchema: Sendable, Equatable {
  public let type: String
  public let summary: String
  public let parameters: [String: RecipeParameterRule]

  public init(type: String, summary: String, parameters: [String: RecipeParameterRule]) {
    self.type = type
    self.summary = summary
    self.parameters = parameters
  }
}

/// AUT-07: the portable recipe format and its validator. Reference boundary:
/// the validator never runs an operation, never resolves a path and never
/// touches the network; it only checks data and migrates supported versions.
public enum RecipePortability {
  public static let maximumBytes = 1_048_576
  public static let maximumOperations = 200
  public static let maximumSettingsDepth = 8
  public static let maximumSettingStringLength = 4_096
  public static let maximumListCount = 1_000
  public static let maximumMetadataKeys = 64

  /// Declared operations of this build. Unknown types are refused, not run.
  public static let operationSchemas: [String: RecipeOperationSchema] = [
    "ocr.recognize": RecipeOperationSchema(
      type: "ocr.recognize", summary: "Recognize text on selected pages.",
      parameters: [
        "pages": RecipeParameterRule(kind: .stringList, required: true),
        "languages": RecipeParameterRule(kind: .stringList),
        "level": RecipeParameterRule(
          kind: .string, allowedValues: ["accurate", "fast"]),
      ]),
    "ocr.batch": RecipeOperationSchema(
      type: "ocr.batch", summary: "Queue OCR for pages that lack a text layer.",
      parameters: [
        "scope": RecipeParameterRule(
          kind: .string, required: true, allowedValues: ["selected", "all"]),
        "languages": RecipeParameterRule(kind: .stringList),
      ]),
    "export.text": RecipeOperationSchema(
      type: "export.text", summary: "Export page text.",
      parameters: [
        "destination": RecipeParameterRule(kind: .string, required: true),
        "includeAnnotations": RecipeParameterRule(kind: .boolean),
      ]),
    "export.html": RecipeOperationSchema(
      type: "export.html", summary: "Export a standalone HTML document.",
      parameters: [
        "destination": RecipeParameterRule(kind: .string, required: true),
        "title": RecipeParameterRule(kind: .string),
      ]),
    "export.docx": RecipeOperationSchema(
      type: "export.docx", summary: "Export an editable DOCX reconstruction.",
      parameters: [
        "destination": RecipeParameterRule(kind: .string, required: true),
        "mode": RecipeParameterRule(kind: .string, allowedValues: ["editable", "appearance"]),
      ]),
    "export.tables": RecipeOperationSchema(
      type: "export.tables", summary: "Export detected tables as CSV or XLSX.",
      parameters: [
        "destination": RecipeParameterRule(kind: .string, required: true),
        "format": RecipeParameterRule(
          kind: .string, required: true, allowedValues: ["csv", "xlsx"]),
        "locale": RecipeParameterRule(
          kind: .string, allowedValues: ["posix", "german", "french"]),
      ]),
    "export.presentation": RecipeOperationSchema(
      type: "export.presentation", summary: "Export a PowerPoint reconstruction with report.",
      parameters: [
        "destination": RecipeParameterRule(kind: .string, required: true),
        "renderDPI": RecipeParameterRule(kind: .number, minimum: 36, maximum: 600),
      ]),
    "optimize": RecipeOperationSchema(
      type: "optimize", summary: "Run the lossless or selected optimization profile.",
      parameters: [
        "profile": RecipeParameterRule(kind: .string, allowedValues: ["lossless", "balanced"]),
      ]),
    "print.pdf": RecipeOperationSchema(
      type: "print.pdf", summary: "Write a print-ready derivative.",
      parameters: [
        "destination": RecipeParameterRule(kind: .string, required: true),
      ]),
    "bates.number": RecipeOperationSchema(
      type: "bates.number", summary: "Apply Bates numbering to selected pages.",
      parameters: [
        "prefix": RecipeParameterRule(kind: .string),
        "start": RecipeParameterRule(kind: .number, minimum: 1, maximum: 1_000_000_000),
      ]),
  ]

  /// Setting or metadata keys that would imply code execution or network
  /// access. A recipe containing one is refused; nothing is ever evaluated.
  static let forbiddenKeys: Set<String> = [
    "script", "javascript", "js", "code", "command", "shell", "exec",
    "execute", "applescript", "osascript", "evaluate", "callback", "handler",
    "url", "uri", "endpoint", "http", "https", "fetch", "webhook", "plugin",
  ]

  static let forbiddenValuePrefixes: [String] = [
    "javascript:", "osascript:", "data:text/javascript", "vbscript:", "file://",
  ]

  // MARK: - Validation

  public static func validate(data: Data) throws -> RecipeValidation {
    guard data.count <= maximumBytes else {
      throw PDFError(.limitExceeded, "The recipe file is larger than the supported limit")
    }
    guard !data.isEmpty else {
      throw PDFError(.malformed, "The recipe file is empty")
    }
    let root: Any
    do {
      root = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      throw PDFError(.malformed, "The recipe is not valid JSON data")
    }
    guard let dictionary = root as? [String: Any] else {
      throw PDFError(.malformed, "The recipe root must be a JSON object")
    }
    try checkDepth(dictionary, depth: 0)
    var issues: [RecipeIssue] = []
    let knownTopLevel: Set<String> = [
      "version", "name", "appVersion", "operations", "metadata",
      // Legacy v0 layout keys.
      "tasks", "createdBy", "title",
    ]
    for key in dictionary.keys.sorted() where !knownTopLevel.contains(key) {
      issues.append(
        RecipeIssue(
          severity: .warning, code: "unknownTopLevelKey",
          message: "The top-level field '\(key)' is not part of the recipe format and "
            + "was ignored; no code is run from it."))
    }

    let rawVersion: Int?
    switch dictionary["version"] {
    case let number as NSNumber: rawVersion = number.intValue
    case let text as String: rawVersion = Int(text)
    default: rawVersion = nil
    }
    guard let version = rawVersion else {
      issues.append(
        RecipeIssue(
          severity: .error, code: "missingVersion",
          message: "The recipe has no numeric format version; it cannot be validated."))
      return RecipeValidation(recipe: nil, issues: issues)
    }
    guard RecipeDocument.supportedReadVersions.contains(version) else {
      let relation = version > RecipeDocument.currentVersion ? "newer" : "unsupported"
      issues.append(
        RecipeIssue(
          severity: .error, code: "unsupportedVersion",
          message: "This recipe uses format version \(version), which is \(relation) than "
            + "the supported version \(RecipeDocument.currentVersion); update sPDF Editor "
            + "or have the recipe exported in a supported version. Nothing was imported."))
      return RecipeValidation(recipe: nil, issues: issues)
    }

    let canonical: [String: Any]
    var migratedFrom: Int?
    if version < RecipeDocument.currentVersion {
      canonical = try migrateLegacy(dictionary, from: version, issues: &issues)
      migratedFrom = version
      issues.append(
        RecipeIssue(
          severity: .warning, code: "migratedVersion",
          message: "The recipe was migrated from format version \(version) to "
            + "\(RecipeDocument.currentVersion); declared defaults were applied and "
            + "ignored legacy fields are listed above."))
    } else {
      canonical = dictionary
    }

    guard let canonicalData = try? JSONSerialization.data(withJSONObject: canonical),
      let recipe = try? JSONDecoder().decode(RecipeDocument.self, from: canonicalData)
    else {
      issues.append(
        RecipeIssue(
          severity: .error, code: "malformedDocument",
          message: "The recipe fields are malformed and could not be read."))
      return RecipeValidation(recipe: nil, issues: issues)
    }

    validateRecipe(recipe, issues: &issues)
    if issues.contains(where: { $0.severity == .error }) {
      return RecipeValidation(recipe: nil, issues: issues, migratedFromVersion: migratedFrom)
    }
    return RecipeValidation(recipe: recipe, issues: issues, migratedFromVersion: migratedFrom)
  }

  static func validateRecipe(_ recipe: RecipeDocument, issues: inout [RecipeIssue]) {
    let name = recipe.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty {
      issues.append(
        RecipeIssue(
          severity: .error, code: "missingName",
          message: "The recipe has no name; a named recipe is required for sharing."))
    }
    if recipe.metadata.count > maximumMetadataKeys {
      issues.append(
        RecipeIssue(
          severity: .error, code: "metadataLimit",
          message: "The recipe has more than \(maximumMetadataKeys) metadata fields."))
    }
    for key in recipe.metadata.keys.sorted() where isForbiddenKey(key) {
      issues.append(
        RecipeIssue(
          severity: .error, code: "forbiddenKey",
          message: "Metadata key '\(key)' is not allowed: recipes are declarative data and "
            + "cannot contain code, commands or network directives."))
    }
    if recipe.operations.count > maximumOperations {
      issues.append(
        RecipeIssue(
          severity: .error, code: "operationLimit",
          message: "The recipe has more than \(maximumOperations) operations."))
      return
    }
    if recipe.operations.isEmpty {
      issues.append(
        RecipeIssue(
          severity: .warning, code: "emptyRecipe",
          message: "The recipe contains no operations; importing it changes no settings."))
    }
    for (index, operation) in recipe.operations.enumerated() {
      validateOperation(operation, index: index, issues: &issues)
    }
  }

  static func validateOperation(
    _ operation: RecipeOperation, index: Int, issues: inout [RecipeIssue]
  ) {
    let type = operation.type.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let schema = operationSchemas[type] else {
      issues.append(
        RecipeIssue(
          severity: .error, code: "unsupportedOperation",
          message: "Operation '\(operation.type)' is not supported by this build; it would "
            + "be incompatible and is not run. Remove it or update sPDF Editor.",
          operationIndex: index))
      return
    }
    if operation.settings.count > 64 {
      issues.append(
        RecipeIssue(
          severity: .error, code: "settingLimit",
          message: "Operation \(index + 1) has more settings than the declared schema allows.",
          operationIndex: index))
    }
    for key in operation.settings.keys.sorted() {
      if isForbiddenKey(key) {
        issues.append(
          RecipeIssue(
            severity: .error, code: "forbiddenKey",
            message: "Operation \(index + 1) uses the forbidden setting '\(key)': recipes "
              + "are declarative and never contain executable or network directives.",
            operationIndex: index))
        continue
      }
      guard let rule = schema.parameters[key] else {
        issues.append(
          RecipeIssue(
            severity: .error, code: "unsupportedSetting",
            message: "Operation \(type) does not declare the setting '\(key)'; the recipe "
              + "was not imported so no setting is silently ignored.",
            operationIndex: index))
        continue
      }
      validateValue(operation.settings[key], rule: rule, key: key, operation: type,
        index: index, issues: &issues)
    }
    for (key, rule) in schema.parameters.sorted(by: { $0.key < $1.key }) where rule.required
      && operation.settings[key] == nil
    {
      issues.append(
        RecipeIssue(
          severity: .error, code: "missingSetting",
          message: "Operation \(type) requires the setting '\(key)'.",
          operationIndex: index))
    }
  }

  static func validateValue(
    _ value: RecipeValue?, rule: RecipeParameterRule, key: String, operation: String,
    index: Int, issues: inout [RecipeIssue]
  ) {
    guard let value else { return }
    var failure: String?
    switch (rule.kind, value) {
    case (.string, .string(let text)):
      if text.count > maximumSettingStringLength { failure = "text is too long" }
      if !rule.allowedValues.isEmpty, !rule.allowedValues.contains(text) {
        failure = "must be one of \(rule.allowedValues.joined(separator: ", "))"
      }
      if let prefix = forbiddenValuePrefixes.first(where: {
        text.lowercased().hasPrefix($0)
      }) {
        failure = "starts with the executable directive \(prefix)"
      }
    case (.number, .number(let number)):
      if !number.isFinite { failure = "is not a finite number" }
      if let minimum = rule.minimum, number < minimum { failure = "is below \(minimum)" }
      if let maximum = rule.maximum, number > maximum { failure = "is above \(maximum)" }
    case (.boolean, .bool):
      break
    case (.stringList, .list(let list)):
      if list.count > maximumListCount { failure = "list is too long" }
      for item in list {
        guard case .string(let text) = item, text.count <= maximumSettingStringLength
        else {
          failure = "list items must be bounded strings"
          break
        }
      }
    default:
      failure = "has the wrong type for the declared setting"
    }
    if let failure {
      issues.append(
        RecipeIssue(
          severity: .error, code: "invalidSetting",
          message: "Operation \(operation) setting '\(key)' \(failure).",
          operationIndex: index))
    }
  }

  static func isForbiddenKey(_ key: String) -> Bool {
    let normalized = key.lowercased()
      .replacingOccurrences(of: "_", with: "")
      .replacingOccurrences(of: "-", with: "")
    return forbiddenKeys.contains(normalized)
  }

  static func checkDepth(_ value: Any, depth: Int) throws {
    guard depth <= maximumSettingsDepth else {
      throw PDFError(.limitExceeded, "The recipe is nested more deeply than the supported limit")
    }
    if let dictionary = value as? [String: Any] {
      for child in dictionary.values { try checkDepth(child, depth: depth + 1) }
    } else if let array = value as? [Any] {
      guard array.count <= maximumListCount else {
        throw PDFError(.limitExceeded, "The recipe contains a list longer than the limit")
      }
      for child in array { try checkDepth(child, depth: depth + 1) }
    } else if let text = value as? String {
      guard text.count <= maximumSettingStringLength * 4 else {
        throw PDFError(.limitExceeded, "The recipe contains a string longer than the limit")
      }
    }
  }

  /// v0 legacy layout: tasks with kind/config; migrated with declared defaults.
  static func migrateLegacy(
    _ dictionary: [String: Any], from version: Int, issues: inout [RecipeIssue]
  ) throws -> [String: Any] {
    guard version == 0 else {
      throw PDFError(.unsupported, "No migration path exists for the recipe format")
    }
    var canonical = dictionary
    canonical.removeValue(forKey: "tasks")
    canonical.removeValue(forKey: "createdBy")
    canonical["version"] = RecipeDocument.currentVersion
    if canonical["name"] == nil, let title = dictionary["title"] as? String {
      canonical["name"] = title
    }
    var operations: [[String: Any]] = []
    if let tasks = dictionary["tasks"] as? [[String: Any]] {
      for task in tasks {
        var operation: [String: Any] = [:]
        if let kind = task["kind"] as? String {
          operation["type"] = kind
        } else if let type = task["type"] as? String {
          operation["type"] = type
        }
        if let config = task["config"] as? [String: Any] {
          operation["settings"] = config
        } else if let settings = task["settings"] as? [String: Any] {
          operation["settings"] = settings
        }
        if let label = task["title"] as? String { operation["label"] = label }
        operations.append(operation)
      }
    }
    canonical["operations"] = operations
    canonical.removeValue(forKey: "title")
    issues.append(
      RecipeIssue(
        severity: .warning, code: "legacyLayout",
        message: "Legacy recipe fields (tasks/kind/config/title) were mapped to the "
          + "version \(RecipeDocument.currentVersion) operations schema."))
    return canonical
  }

  // MARK: - Export and report

  /// AUT-07: deterministic portable JSON in the current format.
  public static func export(_ recipe: RecipeDocument) throws -> Data {
    let canonical = RecipeDocument(
      version: RecipeDocument.currentVersion, name: recipe.name,
      appVersion: recipe.appVersion, operations: recipe.operations,
      metadata: recipe.metadata)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(canonical)
  }

  /// AUT-07: a human-readable compatibility report for an import dialog.
  public static func compatibilityReport(_ validation: RecipeValidation) -> String {
    var lines = [
      "# Recipe compatibility report", "",
      "Format: sPDF recipe v\(RecipeDocument.currentVersion); supported read versions: "
        + RecipeDocument.supportedReadVersions.sorted().map(String.init).joined(separator: ", ")
        + ".",
      "Status: \(validation.isAccepted ? "accepted" : "not imported")"
        + (validation.migratedFromVersion.map { " (migrated from v\($0))" } ?? "") + ".",
      "",
      "Recipes are declarative data: nothing in this file is code, and the validator "
        + "never executes an operation, resolves a destination or uses the network.",
    ]
    if let recipe = validation.recipe {
      lines.append("")
      lines.append("Name: \(recipe.name)")
      if let appVersion = recipe.appVersion {
        lines.append("Exported by: \(appVersion)")
      }
      lines.append("")
      lines.append("| # | Operation | Declared settings |")
      lines.append("| --- | --- | --- |")
      for (index, operation) in recipe.operations.enumerated() {
        let settings = operation.settings.keys.sorted().joined(separator: ", ")
        lines.append(
          "| \(index + 1) | \(operation.type) | \(settings.isEmpty ? "none" : settings) |")
      }
    }
    if !validation.issues.isEmpty {
      lines.append("")
      lines.append("## Compatibility")
      for issue in validation.issues {
        let whereText = issue.operationIndex.map { " (operation \($0 + 1))" } ?? ""
        lines.append("- [\(issue.severity.rawValue)] \(issue.message)\(whereText)")
      }
    }
    return lines.joined(separator: "\n")
  }
}
