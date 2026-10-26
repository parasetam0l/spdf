import Foundation
import PDFCore

// AUT-05: the user-facing automation command line. It is a thin front end over
// the same PDFEditing services the app uses, with a stable documented option
// vocabulary, stable exit codes and a structured JSON envelope. No diagnostic
// flags exist outside AutomationProfile.

public enum AutomationCLI {
  public struct RunResult {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let envelope: [String: Any]?
    public init(
      exitCode: Int32, standardOutput: String, standardError: String,
      envelope: [String: Any]?
    ) {
      self.exitCode = exitCode
      self.standardOutput = standardOutput
      self.standardError = standardError
      self.envelope = envelope
    }
  }

  enum FailureKind: String {
    case usage
    case input
    case unsupported
    case output
    case operation

    var exitCode: Int32 {
      switch self {
      case .usage: return 2
      case .input: return 3
      case .unsupported: return 4
      case .output: return 5
      case .operation: return 6
      }
    }
  }

  struct Failure: Error {
    let kind: FailureKind
    let message: String
  }

  struct ParsedCommand {
    let operation: AutomationProfile.Operation
    let inputs: [String]
    let options: [String: String]
    let format: String
  }

  /// Synchronous entry point used by the executable target. Writes the structured
  /// output to stdout and diagnostics to stderr.
  @discardableResult
  public static func run(
    arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Int32 {
    let result = perform(arguments: arguments, environment: environment)
    if !result.standardOutput.isEmpty {
      FileHandle.standardOutput.write(Data(result.standardOutput.utf8))
    }
    if !result.standardError.isEmpty {
      FileHandle.standardError.write(Data(result.standardError.utf8))
    }
    return result.exitCode
  }

  /// Testable/Scriptable entry point: captures output instead of writing it.
  public static func perform(
    arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> RunResult {
    do {
      let parsed = try parse(arguments: arguments)
      let execution = try execute(parsed, environment: environment)
      let envelope: [String: Any] = [
        "schemaVersion": AutomationProfile.schemaVersion,
        "profile": AutomationProfile.identifier,
        "operation": parsed.operation.name,
        "status": "success",
        "exitCode": 0,
        "result": execution.result,
        "warnings": execution.warnings,
        "restrictions": parsed.operation.restrictions,
      ]
      let stdout: String
      if parsed.format == "text" {
        stdout = execution.humanLines.joined(separator: "\n") + "\n"
      } else {
        stdout = jsonString(envelope) + "\n"
      }
      return RunResult(
        exitCode: 0, standardOutput: stdout, standardError: "", envelope: envelope)
    } catch let failure as Failure {
      let operation = arguments.first ?? ""
      let envelope: [String: Any] = [
        "schemaVersion": AutomationProfile.schemaVersion,
        "profile": AutomationProfile.identifier,
        "operation": operation,
        "status": "error",
        "exitCode": Int(failure.kind.exitCode),
        "error": ["kind": failure.kind.rawValue, "message": failure.message],
        "restrictions": AutomationProfile.restrictions,
      ]
      let wantsJSON: Bool
      if let formatIndex = arguments.firstIndex(of: "--format"),
        formatIndex + 1 < arguments.count, arguments[formatIndex + 1] == "text"
      {
        wantsJSON = false
      } else {
        wantsJSON = true
      }
      let stdout = wantsJSON ? jsonString(envelope) + "\n" : ""
      let stderr =
        "spdf-automation: " + failure.kind.rawValue + ": " + failure.message + "\n"
      return RunResult(
        exitCode: failure.kind.exitCode, standardOutput: stdout, standardError: stderr,
        envelope: envelope)
    } catch {
      let envelope: [String: Any] = [
        "schemaVersion": AutomationProfile.schemaVersion,
        "profile": AutomationProfile.identifier,
        "operation": arguments.first ?? "",
        "status": "error",
        "exitCode": Int(FailureKind.operation.exitCode),
        "error": ["kind": FailureKind.operation.rawValue, "message": error.localizedDescription],
      ]
      return RunResult(
        exitCode: FailureKind.operation.exitCode,
        standardOutput: jsonString(envelope) + "\n",
        standardError: "spdf-automation: operation: " + error.localizedDescription + "\n",
        envelope: envelope)
    }
  }

  // MARK: - Parsing

  static func parse(arguments: [String]) throws -> ParsedCommand {
    guard let operationName = arguments.first else {
      throw Failure(
        kind: .usage,
        message: "Missing operation. Available: "
          + AutomationProfile.operations.map(\.name).joined(separator: ", ") + ".")
    }
    guard let operation = AutomationProfile.operation(named: operationName) else {
      throw Failure(
        kind: .usage,
        message: "Unknown operation '" + operationName + "'. Available: "
          + AutomationProfile.operations.map(\.name).joined(separator: ", ") + ".")
    }
    let allowedOptions = Set(operation.options.map(\.name))
    var options: [String: String] = [:]
    var inputs: [String] = []
    var index = 1
    while index < arguments.count {
      let token = arguments[index]
      if token.hasPrefix("--") {
        guard allowedOptions.contains(token) else {
          throw Failure(
            kind: .usage,
            message: "Option " + token + " is not part of the " + operation.name
              + " profile. See spdf-automation capabilities.")
        }
        guard index + 1 < arguments.count else {
          throw Failure(kind: .usage, message: "Option " + token + " needs a value.")
        }
        guard options[token] == nil else {
          throw Failure(kind: .usage, message: "Option " + token + " was given twice.")
        }
        options[token] = arguments[index + 1]
        index += 2
        continue
      }
      inputs.append(token)
      index += 1
    }
    let format = options["--format"] ?? "json"
    guard format == "json" || format == "text" else {
      throw Failure(kind: .usage, message: "--format must be json or text.")
    }
    if operation.acceptsMultipleInputs {
      guard inputs.count >= 2 else {
        throw Failure(kind: .usage, message: operation.name + " needs at least two input files.")
      }
    } else if operation.name != "capabilities" {
      guard inputs.count == 1 else {
        throw Failure(
          kind: .usage,
          message: operation.name + " needs exactly one input file, got "
            + String(inputs.count) + ".")
      }
    } else if !inputs.isEmpty {
      throw Failure(kind: .usage, message: "capabilities takes no input files.")
    }
    if operation.producesFile {
      guard let output = options["--output"], !output.isEmpty else {
        throw Failure(kind: .usage, message: operation.name + " requires --output.")
      }
      for input in inputs {
        if samePath(input, output) {
          throw Failure(
            kind: .usage,
            message: "--output must not be the input file: " + output + ".")
        }
      }
    }
    if operation.name == "forms-import", options["--values"] == nil {
      throw Failure(kind: .usage, message: "forms-import requires --values.")
    }
    if operation.name == "export-pages", options["--pages"] == nil {
      throw Failure(kind: .usage, message: "export-pages requires --pages.")
    }
    return ParsedCommand(
      operation: operation, inputs: inputs, options: options, format: format)
  }

  static func samePath(_ first: String, _ second: String) -> Bool {
    let a = URL(fileURLWithPath: first).standardizedFileURL.resolvingSymlinksInPath().path
    let b = URL(fileURLWithPath: second).standardizedFileURL.resolvingSymlinksInPath().path
    return a == b
  }

  // MARK: - Execution

  struct Execution {
    let result: [String: Any]
    let warnings: [String]
    let humanLines: [String]
  }

  static func execute(
    _ parsed: ParsedCommand, environment: [String: String]
  ) throws -> Execution {
    let operation = parsed.operation
    switch operation.name {
    case "capabilities":
      let capabilities = AutomationProfile.capabilitiesObject()
      return Execution(
        result: capabilities, warnings: [],
        humanLines: [
          "sPDF automation profile " + AutomationProfile.identifier,
          "Operations: " + AutomationProfile.operations.map(\.name).joined(separator: ", "),
          "Exit codes: "
            + AutomationProfile.exitCodes.map { String($0.code) + "=" + $0.name }
              .joined(separator: ", "),
        ])
    case "info":
      let parsedInput = try parsedInput(parsed, environment: environment)
      let graph = parsedInput.graph
      let pageIDs = try PDFPageTree.pageIDs(in: graph)
      let pageCount = pageIDs.count
      let facts = PDFDocumentInventory.documentFacts(in: graph, pageCount: pageCount)
      let signatures = (try? PDFSignatureInventory.signatures(in: graph)) ?? []
      let fields = (try? FormInventory.fields(in: graph, pageIDs: pageIDs)) ?? []
      let isTagged: Bool = {
        guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
          case .dictionary(let catalog)? = graph.objects[catalogID]
        else { return false }
        return catalog[PDFName("StructTreeRoot")] != nil
      }()
      let result: [String: Any] = [
        "path": parsedInput.path,
        "bytes": parsedInput.byteCount,
        "pages": pageCount,
        "encrypted": facts.security.isEncrypted,
        "allowsExtraction": facts.security.allowsExtraction,
        "signatures": signatures.count,
        "signatureFields": signatures.compactMap { $0.fieldName ?? $0.kind.rawValue },
        "formFields": fields.count,
        "tagged": isTagged,
        "language": facts.metadata.language.map { $0 as Any } ?? NSNull(),
        "title": facts.metadata.title.map { $0 as Any } ?? NSNull(),
        "author": facts.metadata.author.map { $0 as Any } ?? NSNull(),
        "activeContent": [
          "javaScript": facts.activeContent.hasJavaScript,
          "launchActions": facts.activeContent.hasLaunchActions,
          "xfa": facts.activeContent.hasXFA,
          "embeddedFiles": facts.activeContent.hasEmbeddedFiles,
        ],
      ]
      var warnings: [String] = []
      if facts.activeContent.isActive {
        warnings.append(
          "The document carries active content; sPDF reports it and never executes it.")
      }
      if facts.security.isEncrypted {
        warnings.append("The document is encrypted; it was read with the supplied password.")
      }
      return Execution(
        result: result, warnings: warnings,
        humanLines: [
          parsedInput.path + ": " + String(pageCount) + " page(s), "
            + String(fields.count) + " form field(s), " + String(signatures.count)
            + " signature(s)"
            + (isTagged ? ", tagged" : ", not tagged")
            + (facts.security.isEncrypted ? ", encrypted" : ""),
        ])
    case "text":
      let parsedInput = try parsedInput(parsed, environment: environment)
      let graph = parsedInput.graph
      let pageIDs = try PDFPageTree.pageIDs(in: graph)
      let selection = try selectedPages(parsed, pageIDs: pageIDs)
      var pages: [[String: Any]] = []
      for pageID in selection {
        let layout = try PageTextLayout.build(pageID: pageID, in: graph)
        var lines: [String] = []
        for range in layout.lines {
          let text = range.map { layout.clusters[$0].text }.joined()
            .trimmingCharacters(in: .whitespaces)
          if !text.isEmpty { lines.append(text) }
        }
        let pageIndex = pageIDs.firstIndex(of: pageID) ?? 0
        pages.append([
          "page": pageIndex + 1,
          "lines": lines,
          "text": lines.joined(separator: "\n"),
        ])
      }
      return Execution(
        result: ["pages": pages, "pageCount": pages.count],
        warnings: ["Text follows the visual layout order; tagged order is reported by audit."],
        humanLines: [
          parsedInput.path + ": " + String(pages.count) + " page(s) of text extracted.",
        ])
    case "export-pages":
      let parsedInput = try parsedInput(parsed, environment: environment)
      let graph = parsedInput.graph
      let pageIDs = try PDFPageTree.pageIDs(in: graph)
      let selection = try selectedPages(parsed, pageIDs: pageIDs)
      let extracted = try DocumentAssembly.extract(
        graph, pageIDs: selection, labels: .preserve, catalogData: .firstDocument)
      let outputPath = parsed.options["--output"] ?? ""
      let data = try PDFWriter.write(extracted.graph)
      try writeOutput(data, to: outputPath)
      return Execution(
        result: [
          "input": parsedInput.path, "output": outputPath, "outputBytes": data.count,
          "pages": selection.count,
          "notes": extracted.report.notes,
        ],
        warnings: signedWarning(graph),
        humanLines: [
          "Exported " + String(selection.count) + " page(s) to " + outputPath + ".",
        ])
    case "merge":
      var sources: [(graph: PDFGraph, pageIDs: [PDFObjectID])] = []
      var inputPaths: [String] = []
      for input in parsed.inputs {
        let parsedInput = try parsedInput(path: input, options: parsed.options, environment: environment)
        sources.append((graph: parsedInput.graph, pageIDs: try PDFPageTree.pageIDs(in: parsedInput.graph)))
        inputPaths.append(parsedInput.path)
      }
      let merged = try DocumentAssembly.merge(sources)
      let outputPath = parsed.options["--output"] ?? ""
      let data = try PDFWriter.write(merged.graph)
      try writeOutput(data, to: outputPath)
      return Execution(
        result: [
          "inputs": inputPaths, "output": outputPath, "outputBytes": data.count,
          "renamedFields": merged.report.renamedFields,
          "notes": merged.report.notes,
        ],
        warnings: [],
        humanLines: [
          "Merged " + String(inputPaths.count) + " file(s) into " + outputPath
            + " (" + String(data.count) + " bytes).",
        ])
    case "forms-export":
      let parsedInput = try parsedInput(parsed, environment: environment)
      let graph = parsedInput.graph
      let pageIDs = try PDFPageTree.pageIDs(in: graph)
      let data = try FormValues.export(in: graph, pageIDs: pageIDs)
      let outputPath = parsed.options["--output"] ?? ""
      try writeOutput(data, to: outputPath)
      let object = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
      return Execution(
        result: [
          "input": parsedInput.path, "output": outputPath,
          "values": object,
        ],
        warnings: [],
        humanLines: ["Exported form values to " + outputPath + "."])
    case "forms-import":
      let parsedInput = try parsedInput(parsed, environment: environment)
      var graph = parsedInput.graph
      let pageIDs = try PDFPageTree.pageIDs(in: graph)
      let valuesPath = parsed.options["--values"] ?? ""
      let valuesData: Data
      do {
        valuesData = try Data(contentsOf: URL(fileURLWithPath: valuesPath))
      } catch {
        throw Failure(
          kind: .input, message: "Cannot read --values file: " + valuesPath + ".")
      }
      let values = try FormValues.parse(valuesData)
      let mapping = try FormValues.commands(for: values, in: graph, pageIDs: pageIDs)
      var warnings = signedWarning(graph) + mapping.skipped.map {
        "Skipped " + $0 + ": unknown, read-only or type-mismatched field."
      } + mapping.ambiguous.map {
        "Field " + $0 + " has several same-named fields; only the first was considered."
      }
      if !mapping.commands.isEmpty {
        graph = try PDFEditingEngine.commit(PDFTransaction(mapping.commands), to: graph)
      }
      let outputPath = parsed.options["--output"] ?? ""
      let data = try PDFWriter.write(graph)
      try writeOutput(data, to: outputPath)
      return Execution(
        result: [
          "input": parsedInput.path, "output": outputPath, "outputBytes": data.count,
          "applied": values.count - mapping.skipped.count,
          "skipped": mapping.skipped, "ambiguous": mapping.ambiguous,
        ],
        warnings: warnings,
        humanLines: [
          "Applied " + String(values.count - mapping.skipped.count) + " value(s), skipped "
            + String(mapping.skipped.count) + ", wrote " + outputPath + ".",
        ])
    case "flatten-forms":
      var parsedInput = try parsedInput(parsed, environment: environment)
      let outputPath = parsed.options["--output"] ?? ""
      let flattened = try PDFEditingEngine.commit(
        PDFTransaction([FlattenFormCommand()]), to: parsedInput.graph)
      parsedInput.graph = flattened
      let data = try PDFWriter.write(flattened)
      try writeOutput(data, to: outputPath)
      return Execution(
        result: [
          "input": parsedInput.path, "output": outputPath, "outputBytes": data.count,
        ],
        warnings: signedWarning(flattened),
        humanLines: ["Flattened forms into " + outputPath + "."])
    case "audit":
      let parsedInput = try parsedInput(parsed, environment: environment)
      let graph = parsedInput.graph
      let pageIDs = try PDFPageTree.pageIDs(in: graph)
      let audit = PDFAccessibilityAudit.audit(graph, pageIDs: pageIDs)
      let validation = FormSaveValidation.validate(in: graph, pageIDs: pageIDs)
      var accessibilityFindingsJSON: [[String: Any]] = []
      for finding in audit.findings {
        accessibilityFindingsJSON.append([
          "rule": finding.rule, "severity": finding.severity.rawValue,
          "detail": finding.detail,
        ])
      }
      var validationFindingsJSON: [[String: Any]] = []
      for finding in validation.findings {
        validationFindingsJSON.append([
          "code": finding.code.rawValue, "severity": finding.severity.rawValue,
          "field": finding.fieldName.map { $0 as Any } ?? NSNull(),
          "message": finding.message,
        ])
      }
      let result: [String: Any] = [
        "input": parsedInput.path,
        "accessibility": [
          "passesMachineChecks": audit.passesMachineChecks,
          "errorCount": audit.errorCount,
          "warningCount": audit.warningCount,
          "findings": accessibilityFindingsJSON,
          "humanReviewRequirements": audit.humanReviewRequirements,
        ],
        "formValidation": [
          "summary": validation.summary,
          "hasBlockingErrors": validation.hasBlockingErrors,
          "findings": validationFindingsJSON,
        ],
        "conformanceClaim": false,
      ]
      return Execution(
        result: result,
        warnings: [
          "Machine checks only; human-review requirements are listed and never marked as passed.",
          "No accessibility-conformance claim is made.",
        ],
        humanLines: [
          parsedInput.path + ": " + validation.summary + " Accessibility findings: "
            + String(audit.findings.count) + ".",
        ])
    default:
      throw Failure(kind: .usage, message: "Operation is not implemented.")
    }
  }

  struct ParsedInput {
    let path: String
    var graph: PDFGraph
    let byteCount: Int
  }

  static func parsedInput(
    _ parsed: ParsedCommand, environment: [String: String]
  ) throws -> ParsedInput {
    guard let input = parsed.inputs.first else {
      throw Failure(kind: .usage, message: "Missing input file.")
    }
    return try parsedInput(
      path: input, options: parsed.options, environment: environment)
  }

  static func parsedInput(
    path: String, options: [String: String], environment: [String: String]
  ) throws -> ParsedInput {
    let url = URL(fileURLWithPath: path)
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw Failure(kind: .input, message: "Cannot read input file: " + path + ".")
    }
    let password =
      options["--password"] ?? environment["SPDF_AUTOMATION_PASSWORD"]
    do {
      let parsed = try PDFParser.parse(data, password: password)
      return ParsedInput(path: url.standardizedFileURL.path, graph: parsed.graph,
        byteCount: data.count)
    } catch let error as PDFError {
      throw Failure(
        kind: .input, message: "Cannot parse input: " + error.localizedDescription)
    } catch {
      throw Failure(kind: .input, message: "Cannot parse input: " + error.localizedDescription)
    }
  }

  static func selectedPages(
    _ parsed: ParsedCommand, pageIDs: [PDFObjectID]
  ) throws -> [PDFObjectID] {
    guard let spec = parsed.options["--pages"] else { return pageIDs }
    let selection = try pageIndices(spec, pageCount: pageIDs.count)
    guard !selection.isEmpty else {
      throw Failure(kind: .usage, message: "--pages selected no pages.")
    }
    return selection.map { pageIDs[$0] }
  }

  static func pageIndices(_ spec: String, pageCount: Int) throws -> [Int] {
    var indices: [Int] = []
    var seen = Set<Int>()
    for part in spec.split(separator: ",") {
      let token = String(part).trimmingCharacters(in: .whitespaces)
      guard !token.isEmpty else { continue }
      let pieces = token.split(separator: "-", omittingEmptySubsequences: false)
      if pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty,
        let start = Int(pieces[0]), let end = Int(pieces[1])
      {
        guard start >= 1, end >= start, end <= pageCount else {
          throw Failure(
            kind: .usage,
            message: "--pages range " + token + " is outside 1..." + String(pageCount) + ".")
        }
        for page in start...end where !seen.contains(page - 1) {
          seen.insert(page - 1)
          indices.append(page - 1)
        }
      } else if let page = Int(token) {
        guard page >= 1, page <= pageCount else {
          throw Failure(
            kind: .usage,
            message: "--pages page " + token + " is outside 1..." + String(pageCount) + ".")
        }
        if !seen.contains(page - 1) {
          seen.insert(page - 1)
          indices.append(page - 1)
        }
      } else {
        throw Failure(kind: .usage, message: "Invalid --pages value: " + spec + ".")
      }
    }
    return indices
  }

  static func writeOutput(_ data: Data, to path: String) throws {
    guard !path.isEmpty else {
      throw Failure(kind: .usage, message: "Writing operation requires --output.")
    }
    let url = URL(fileURLWithPath: path)
    let directory = url.deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw Failure(
        kind: .output, message: "The output directory does not exist: " + directory.path + ".")
    }
    do {
      try data.write(to: url, options: .atomic)
    } catch {
      throw Failure(
        kind: .output, message: "Cannot write output " + path + ": " + error.localizedDescription)
    }
  }

  static func signedWarning(_ graph: PDFGraph) -> [String] {
    let signatures = (try? PDFSignatureInventory.signatures(in: graph)) ?? []
    guard !signatures.isEmpty else { return [] }
    return [
      "The input is signed; writing a new file does not preserve the signature validity of the "
        + "changed revision."
    ]
  }

  static func jsonString(_ object: [String: Any]) -> String {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
  }
}
