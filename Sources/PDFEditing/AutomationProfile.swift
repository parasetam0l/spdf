import Foundation

// AUT-05: the declared automation profile. The native CLI, the Shortcuts/App
// Intents surface and the AppleScript bridge all use this one catalog, so
// automation cannot exceed or hide capabilities of the UI. Options, exit codes,
// restrictions and the JSON envelope are stable and documented here rather than
// behind diagnostic flags.

public enum AutomationProfile {
  public static let identifier = "spdf-automation-v1"
  public static let schemaVersion = 1

  public enum OperationKind: String, Sendable, Equatable {
    case read
    case write
  }

  public struct Option: Sendable, Equatable {
    public let name: String
    public let valueDescription: String
    public let required: Bool
    public let summary: String

    public init(name: String, valueDescription: String, required: Bool, summary: String) {
      self.name = name
      self.valueDescription = valueDescription
      self.required = required
      self.summary = summary
    }
  }

  public struct Operation: Sendable, Equatable {
    public let name: String
    public let summary: String
    public let usage: String
    public let kind: OperationKind
    public let options: [Option]
    public let restrictions: [String]
    public let acceptsMultipleInputs: Bool
    public let producesFile: Bool

    public init(
      name: String, summary: String, usage: String, kind: OperationKind, options: [Option],
      restrictions: [String], acceptsMultipleInputs: Bool, producesFile: Bool
    ) {
      self.name = name
      self.summary = summary
      self.usage = usage
      self.kind = kind
      self.options = options
      self.restrictions = restrictions
      self.acceptsMultipleInputs = acceptsMultipleInputs
      self.producesFile = producesFile
    }
  }

  public struct ExitCode: Sendable, Equatable {
    public let code: Int32
    public let name: String
    public let meaning: String
    public init(code: Int32, name: String, meaning: String) {
      self.code = code
      self.name = name
      self.meaning = meaning
    }
  }

  public static let exitCodes: [ExitCode] = [
    ExitCode(code: 0, name: "success", meaning: "The operation completed."),
    ExitCode(code: 2, name: "usage", meaning: "Unknown operation, bad option or missing argument."),
    ExitCode(code: 3, name: "input", meaning: "An input file is missing, unreadable or malformed."),
    ExitCode(
      code: 4, name: "unsupported",
      meaning: "The input or request is outside the declared automation profile"),
    ExitCode(code: 5, name: "output", meaning: "The output file could not be written."),
    ExitCode(code: 6, name: "operation", meaning: "The declared operation failed."),
  ]

  public static let restrictions: [String] = [
    "Never executes document JavaScript, embedded actions, launch actions or XFA scripts.",
    "No network, cloud OCR or signing operation is exposed; signing needs an identity and is "
      + "outside this profile.",
    "Writing operations never overwrite an input file; --output is required for them.",
    "Encrypted documents need --password or the SPDF_AUTOMATION_PASSWORD environment variable; "
      + "the password is never echoed or written to output.",
    "Signed documents can be read; writing them invalidates signatures and is reported as a "
      + "warning instead of being hidden.",
    "Only the documented options below are accepted; unknown flags and hidden diagnostic flags "
      + "are refused with the usage exit code.",
    "The accessibility audit separates machine-checkable findings from human-review "
      + "requirements and is not an accessibility-conformance claim.",
    "Native Shortcuts, AppleScript and the CLI share this catalog: they expose the same "
      + "capabilities and the same restrictions as the UI automation surface.",
  ]

  private static let pagesOption = Option(
    name: "--pages", valueDescription: "1,3-5", required: false,
    summary: "One-based page selection for text and export-pages.")
  private static let outputOption = Option(
    name: "--output", valueDescription: "path", required: false,
    summary: "Destination file; required for writing operations and never an input path.")
  private static let valuesOption = Option(
    name: "--values", valueDescription: "path", required: false,
    summary: "JSON form-value file for forms-import.")
  private static let passwordOption = Option(
    name: "--password", valueDescription: "text", required: false,
    summary: "Password for an encrypted input. Prefer SPDF_AUTOMATION_PASSWORD.")
  private static let formatOption = Option(
    name: "--format", valueDescription: "json|text", required: false,
    summary: "Output format; JSON is the default structured envelope.")

  public static let operations: [Operation] = [
    Operation(
      name: "capabilities",
      summary: "Print this profile, its operations, options, exit codes and restrictions.",
      usage: "spdf-automation capabilities [--format json|text]",
      kind: .read, options: [formatOption],
      restrictions: ["No file is read or written."], acceptsMultipleInputs: false,
      producesFile: false),
    Operation(
      name: "info",
      summary: "Report document facts: pages, encryption, signatures, fields, tagging, metadata.",
      usage: "spdf-automation info input.pdf [--password text] [--format json|text]",
      kind: .read, options: [passwordOption, formatOption],
      restrictions: ["Read-only; no document action is executed."], acceptsMultipleInputs: false,
      producesFile: false),
    Operation(
      name: "text",
      summary: "Extract the visual-order text of the selected pages as JSON.",
      usage: "spdf-automation text input.pdf [--pages 1,3-5] [--password text] "
        + "[--format json|text]",
      kind: .read, options: [pagesOption, passwordOption, formatOption],
      restrictions: [
        "Visual reading order only; tagged reading order and OCR quality are not claimed.",
        "Text that the document does not encode is not invented.",
      ], acceptsMultipleInputs: false, producesFile: false),
    Operation(
      name: "export-pages",
      summary: "Write the selected pages to a new PDF.",
      usage: "spdf-automation export-pages input.pdf --pages 1,3-5 --output out.pdf",
      kind: .write, options: [pagesOption, outputOption, passwordOption, formatOption],
      restrictions: [
        "The output is a new file; the input is never overwritten.",
        "Encrypted inputs must be unlocked with a password; a signed input stays signed only "
          + "in the copied bytes, and the new file is a page subset.",
      ], acceptsMultipleInputs: false, producesFile: true),
    Operation(
      name: "merge",
      summary: "Merge two or more PDFs into one new PDF with collision-free object remapping.",
      usage: "spdf-automation merge first.pdf second.pdf --output out.pdf",
      kind: .write, options: [outputOption, passwordOption, formatOption],
      restrictions: [
        "Encrypted or signed inputs are refused; the input files are never modified.",
        "Document-level catalog data follows the existing merge policy and is reported.",
      ], acceptsMultipleInputs: true, producesFile: true),
    Operation(
      name: "forms-export",
      summary: "Export supported form values to the JSON form-value schema.",
      usage: "spdf-automation forms-export input.pdf --output values.json",
      kind: .read, options: [outputOption, passwordOption, formatOption],
      restrictions: [
        "Only text, choice and button values are exported; scripts and actions are never executed.",
      ], acceptsMultipleInputs: false, producesFile: false),
    Operation(
      name: "forms-import",
      summary: "Apply JSON form values to a new PDF copy.",
      usage: "spdf-automation forms-import input.pdf --values values.json --output out.pdf",
      kind: .write, options: [valuesOption, outputOption, passwordOption, formatOption],
      restrictions: [
        "Unknown fields, read-only fields and type mismatches are reported as skipped, never "
          + "guessed.",
        "The output is a new file; the input is never overwritten.",
      ], acceptsMultipleInputs: false, producesFile: true),
    Operation(
      name: "flatten-forms",
      summary: "Flatten form fields and their appearances into page content in a new PDF.",
      usage: "spdf-automation flatten-forms input.pdf --output out.pdf",
      kind: .write, options: [outputOption, passwordOption, formatOption],
      restrictions: [
        "The output is a new file; no document action is executed.",
        "Signature fields and signed revisions are not repaired or preserved as fillable.",
      ], acceptsMultipleInputs: false, producesFile: true),
    Operation(
      name: "audit",
      summary: "Run the accessibility audit and the save-time form validation; report findings.",
      usage: "spdf-automation audit input.pdf [--password text] [--format json|text]",
      kind: .read, options: [passwordOption, formatOption],
      restrictions: [
        "Machine checks only; human-review requirements are listed separately and never marked "
          + "as passed.",
        "No accessibility-conformance claim is made.",
      ], acceptsMultipleInputs: false, producesFile: false),
  ]

  public static func operation(named name: String) -> Operation? {
    operations.first { $0.name == name }
  }

  public static func capabilitiesObject() -> [String: Any] {
    [
      "identifier": identifier,
      "schemaVersion": schemaVersion,
      "envelope": [
        "schemaVersion": schemaVersion,
        "fields": ["schemaVersion", "profile", "operation", "status", "exitCode", "result",
          "warnings", "restrictions"],
      ],
      "operations": operations.map { operation -> [String: Any] in
        [
          "name": operation.name,
          "summary": operation.summary,
          "usage": operation.usage,
          "kind": operation.kind.rawValue,
          "acceptsMultipleInputs": operation.acceptsMultipleInputs,
          "producesFile": operation.producesFile,
          "options": operation.options.map { option -> [String: Any] in
            [
              "name": option.name,
              "value": option.valueDescription,
              "required": option.required,
              "summary": option.summary,
            ]
          },
          "restrictions": operation.restrictions,
        ]
      },
      "exitCodes": exitCodes.map { code -> [String: Any] in
        ["code": Int(code.code), "name": code.name, "meaning": code.meaning]
      },
      "restrictions": restrictions,
      "environment": [
        "SPDF_AUTOMATION_PASSWORD": "Password for encrypted inputs when --password is omitted."
      ],
      "nativeSurfaces": [
        "Command line: spdf-automation (this profile).",
        "Shortcuts / App Intents: the same profile operations through Run Automation.",
        "AppleScript: the same profile operations through the Spdf Automation command suite.",
      ],
    ]
  }

  public static func capabilitiesJSON() -> Data? {
    try? JSONSerialization.data(
      withJSONObject: capabilitiesObject(), options: [.prettyPrinted, .sortedKeys])
  }
}
