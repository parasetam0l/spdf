import CryptoKit
import Foundation
import PDFCore

/// P37-012/P37-013: a staged archival derivative. The plan lists every
/// transformation with its content impact; staging applies only the selected
/// ones and **never** writes a PDF/A identifier or output intent before
/// independent validation succeeds.
public struct ArchivalDerivativePlan: Sendable, Equatable {
  public struct Transformation: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
      /// Remove `/OpenAction`, `/AA`, and executable annotation actions.
      case removeExecutableActions
      /// Remove `/NeedAppearances` (form rendering may change where appearance
      /// streams are missing).
      case removeNeedAppearances
      /// Add a deterministic trailer `/ID` (no visible change).
      case addFileIdentifier
      /// Remove the `/EmbeddedFiles` name tree (content removal).
      case removeEmbeddedFiles

      /// P37-028: what applying this transformation can change.
      public var contentImpact: String {
        switch self {
        case .removeExecutableActions:
          return "Behavior only: executable actions are removed; visible content is unchanged."
        case .removeNeedAppearances:
          return "Rendering: fields without appearance streams may render differently until appearances are generated."
        case .addFileIdentifier:
          return "No visible change: a deterministic trailer /ID is added."
        case .removeEmbeddedFiles:
          return "Content removed: embedded file attachments are deleted."
        }
      }

      /// Transformations that silently discard content or change rendering
      /// require an explicit user decision.
      public var requiresUserDecision: Bool {
        switch self {
        case .removeExecutableActions, .addFileIdentifier: return false
        case .removeNeedAppearances, .removeEmbeddedFiles: return true
        }
      }
    }

    public let kind: Kind
    public let detail: String

    public init(kind: Kind, detail: String) {
      self.kind = kind
      self.detail = detail
    }
  }

  public let profile: ArchivalProfile
  public let transformations: [Transformation]
  /// Requirements this profile cannot satisfy by transformation alone.
  public let unresolvedRequirements: [String]
  public let inventory: ArchivalInventory

  public init(
    profile: ArchivalProfile, transformations: [Transformation],
    unresolvedRequirements: [String], inventory: ArchivalInventory
  ) {
    self.profile = profile
    self.transformations = transformations
    self.unresolvedRequirements = unresolvedRequirements
    self.inventory = inventory
  }

  /// Transformations safe to apply without a user decision.
  public var safeKinds: [Transformation.Kind] {
    transformations.filter { !$0.kind.requiresUserDecision }.map(\.kind)
  }

  public func report() -> String {
    var lines = [
      "Archival derivative plan — \(profile.rawValue) (\(profile.standard))",
      "No PDF/A identifier is written by staging; independent validation decides.",
    ]
    if transformations.isEmpty {
      lines.append("  No transformations are available for this document.")
    }
    for transformation in transformations {
      let decision = transformation.kind.requiresUserDecision ? "requires decision" : "safe"
      lines.append(
        "  [\(decision)] \(transformation.kind.rawValue): \(transformation.detail) — \(transformation.kind.contentImpact)")
    }
    if !unresolvedRequirements.isEmpty {
      lines.append("  Unresolved requirements (cannot be fixed by staging alone):")
      for requirement in unresolvedRequirements {
        lines.append("    - \(requirement)")
      }
    }
    return lines.joined(separator: "\n")
  }
}

/// P37-014: an independent validator's verdict (veraPDF when available).
public struct ArchivalValidationResult: Sendable, Equatable {
  public struct FailingRule: Sendable, Equatable {
    public let specification: String
    public let clause: String
    public let description: String
    public let failedChecks: Int

    public init(specification: String, clause: String, description: String, failedChecks: Int) {
      self.specification = specification
      self.clause = clause
      self.description = description
      self.failedChecks = failedChecks
    }
  }

  public let validator: String
  public let validatorVersion: String?
  public let profileName: String
  public let isCompliant: Bool
  public let passedRules: Int
  public let failedRules: Int
  public let failedChecks: Int
  public let failingRules: [FailingRule]

  public init(
    validator: String, validatorVersion: String?, profileName: String, isCompliant: Bool,
    passedRules: Int, failedRules: Int, failedChecks: Int, failingRules: [FailingRule]
  ) {
    self.validator = validator
    self.validatorVersion = validatorVersion
    self.profileName = profileName
    self.isCompliant = isCompliant
    self.passedRules = passedRules
    self.failedRules = failedRules
    self.failedChecks = failedChecks
    self.failingRules = failingRules
  }

  public func report() -> String {
    var lines = [
      "Independent archival validation — \(validator) \(validatorVersion ?? "?")",
      "Profile: \(profileName)",
      "No PDF/A identifier is written by this app; the verdict below is the validator's.",
      isCompliant
        ? "Verdict: compliant."
        : "Verdict: not compliant (\(failedRules) failed rule\(failedRules == 1 ? "" : "s"), \(failedChecks) failed check\(failedChecks == 1 ? "" : "s")).",
    ]
    for rule in failingRules.prefix(20) {
      lines.append("  [\(rule.clause)] \(rule.description) (\(rule.failedChecks) checks)")
    }
    if failingRules.count > 20 {
      lines.append("  … \(failingRules.count - 20) more failing rules")
    }
    return lines.joined(separator: "\n")
  }
}

public enum ArchivalDerivative {
  public static let defaultValidatorPath = "/opt/homebrew/bin/verapdf"

  /// P37-012: plan the staged transformations for the chosen profile.
  public static func plan(
    _ graph: PDFGraph, pageIDs: [PDFObjectID], profile: ArchivalProfile = .selected
  ) -> ArchivalDerivativePlan {
    let inventory = ArchivalInventory.inventory(graph, pageIDs: pageIDs, profile: profile)
    var transformations: [ArchivalDerivativePlan.Transformation] = []

    let actionFindings = inventory.findings.filter { $0.rule == "Executable actions" }
    if !actionFindings.isEmpty {
      transformations.append(
        .init(
          kind: .removeExecutableActions,
          detail: "\(actionFindings.reduce(0) { $0 + $1.count }) executable action key(s) found."))
    }
    if inventory.findings.contains(where: { $0.rule == "NeedAppearances" && $0.count > 0 }) {
      transformations.append(
        .init(
          kind: .removeNeedAppearances,
          detail: "AcroForm /NeedAppearances is true."))
    }
    if inventory.findings.contains(where: { $0.rule == "File identifier" && $0.count == 0 }) {
      transformations.append(
        .init(kind: .addFileIdentifier, detail: "The trailer has no /ID entry."))
    }
    if inventory.findings.contains(where: { $0.rule == "Embedded files" && $0.count > 0 }) {
      transformations.append(
        .init(
          kind: .removeEmbeddedFiles,
          detail: "Embedded files are present and forbidden for \(profile.rawValue)."))
    }

    var unresolved: [String] = []
    if inventory.findings.contains(where: { $0.rule == "Font embedding" && $0.count > 0 }) {
      unresolved.append(
        "Font embedding: this profile does not embed font programs; the listed fonts must be embedded by an authorized source.")
    }
    if inventory.findings.contains(where: { $0.rule == "OutputIntent" && $0.severity == .error }) {
      unresolved.append(
        "Output intent: a licensed ICC destination profile is required; none is bundled.")
    }
    unresolved.append(
      "XMP PDF/A identification: added only after independent validation succeeds (P37-013).")

    return ArchivalDerivativePlan(
      profile: profile, transformations: transformations, unresolvedRequirements: unresolved,
      inventory: inventory)
  }

  /// P37-012/P37-013: apply only the chosen transformations. Never adds a
  /// PDF/A identifier, output intent, or XMP metadata.
  public static func stage(
    _ graph: PDFGraph, plan: ArchivalDerivativePlan, applying kinds: [ArchivalDerivativePlan.Transformation.Kind]
  ) throws -> (graph: PDFGraph, applied: [ArchivalDerivativePlan.Transformation.Kind], skipped: [ArchivalDerivativePlan.Transformation.Kind]) {
    let requested = Set(kinds)
    var staged = graph
    var applied: [ArchivalDerivativePlan.Transformation.Kind] = []
    for transformation in plan.transformations where requested.contains(transformation.kind) {
      switch transformation.kind {
      case .removeExecutableActions:
        staged = removingExecutableActions(from: staged)
      case .removeNeedAppearances:
        staged = removingNeedAppearances(from: staged)
      case .addFileIdentifier:
        staged = try addingFileIdentifier(to: staged)
      case .removeEmbeddedFiles:
        staged = removingEmbeddedFiles(from: staged)
      }
      applied.append(transformation.kind)
    }
    let skipped = plan.transformations.map(\.kind).filter { !requested.contains($0) }
    return (staged, applied, skipped)
  }

  // MARK: - Transformations

  static func removingExecutableActions(from graph: PDFGraph) -> PDFGraph {
    var objects = graph.objects
    for (id, value) in Array(objects) {
      guard case .dictionary(var dictionary) = value else { continue }
      var changed = false
      if dictionary[PDFName("AA")] != nil {
        dictionary[PDFName("AA")] = nil
        changed = true
      }
      if case .dictionary(let action)? = dictionary[PDFName("A")],
        case .name(let subtype)? = action[PDFName("S")]
      {
        let name = String(decoding: subtype.bytes, as: UTF8.self)
        if ["JavaScript", "Launch", "Sound", "Movie", "Rendition", "SubmitForm", "ImportData"]
          .contains(name)
        {
          dictionary[PDFName("A")] = nil
          changed = true
        }
      }
      if changed { objects[id] = .dictionary(dictionary) }
    }
    if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = objects[catalogID]
    {
      if catalog[PDFName("OpenAction")] != nil {
        catalog[PDFName("OpenAction")] = nil
        objects[catalogID] = .dictionary(catalog)
      }
    }
    return PDFGraph(version: graph.version, objects: objects, trailer: graph.trailer)
  }

  static func removingNeedAppearances(from graph: PDFGraph) -> PDFGraph {
    var objects = graph.objects
    for (id, value) in Array(objects) {
      guard case .dictionary(var dictionary) = value,
        case .dictionary(var form)? = dictionary[PDFName("AcroForm")],
        form[PDFName("NeedAppearances")] != nil
      else { continue }
      form[PDFName("NeedAppearances")] = nil
      dictionary[PDFName("AcroForm")] = .dictionary(form)
      objects[id] = .dictionary(dictionary)
    }
    return PDFGraph(version: graph.version, objects: objects, trailer: graph.trailer)
  }

  static func removingEmbeddedFiles(from graph: PDFGraph) -> PDFGraph {
    var objects = graph.objects
    if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = objects[catalogID],
      case .dictionary(var names)? = catalog[PDFName("Names")]
    {
      if names[PDFName("EmbeddedFiles")] != nil {
        names[PDFName("EmbeddedFiles")] = nil
        catalog[PDFName("Names")] = names.isEmpty ? nil : .dictionary(names)
        objects[catalogID] = .dictionary(catalog)
      }
    }
    return PDFGraph(version: graph.version, objects: objects, trailer: graph.trailer)
  }

  /// Deterministic trailer `/ID` from the serialized graph without an ID.
  static func addingFileIdentifier(to graph: PDFGraph) throws -> PDFGraph {
    var withoutID = graph
    withoutID.trailer[PDFName("ID")] = nil
    let data = try PDFWriter.write(withoutID)
    let digest = SHA256.hash(data: data)
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    let identifier = Data(hex.utf8)
    var trailer = graph.trailer
    trailer[PDFName("ID")] = .array([.string(identifier), .string(identifier)])
    return PDFGraph(version: graph.version, objects: graph.objects, trailer: trailer)
  }

  // MARK: - Independent validation (P37-014)

  /// Run an independent validator on the staged bytes. Returns nil when the
  /// validator is unavailable or cannot be run — never a guessed verdict.
  public static func validate(
    _ data: Data, profile: ArchivalProfile = .selected,
    validatorPath: String = defaultValidatorPath
  ) -> ArchivalValidationResult? {
    // The only selected archival profile is PDF/A-2b.
    runValidator(data: data, flavour: "2b", validatorPath: validatorPath)
  }

  /// P37-017: independent PDF/UA validation (veraPDF `ua1` flavour).
  public static func validateAccessibility(
    _ data: Data, validatorPath: String = defaultValidatorPath
  ) -> ArchivalValidationResult? {
    runValidator(data: data, flavour: "ua1", validatorPath: validatorPath)
  }

  static func runValidator(
    data: Data, flavour: String, validatorPath: String
  ) -> ArchivalValidationResult? {
    guard FileManager.default.isExecutableFile(atPath: validatorPath) else { return nil }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-archive-\(UUID().uuidString)", isDirectory: true)
    guard (try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)) != nil
    else { return nil }
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("staged.pdf")
    guard (try? data.write(to: file)) != nil else { return nil }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: validatorPath)
    process.arguments = ["--flavour", flavour, "--format", "xml", file.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
      try process.run()
    } catch {
      return nil
    }
    process.waitUntilExit()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    guard !output.isEmpty, let document = try? XMLDocument(data: output) else { return nil }
    return parse(validator: "veraPDF", report: document)
  }

  static func parse(validator: String, report: XMLDocument) -> ArchivalValidationResult? {
    func attribute(_ name: String, at path: String) -> String? {
      guard let node = try? report.nodes(forXPath: path).first as? XMLElement else { return nil }
      return node.attribute(forName: name)?.stringValue
    }
    guard
      let validation = try? report.nodes(forXPath: "//*[local-name()='validationReport']").first
        as? XMLElement
    else { return nil }
    let isCompliant = validation.attribute(forName: "isCompliant")?.stringValue == "true"
    let profileName = validation.attribute(forName: "profileName")?.stringValue ?? "unknown"
    let passedRules = Int(attribute("passedRules", at: "//*[local-name()='details']") ?? "") ?? 0
    let failedRules = Int(attribute("failedRules", at: "//*[local-name()='details']") ?? "") ?? 0
    let failedChecks = Int(attribute("failedChecks", at: "//*[local-name()='details']") ?? "") ?? 0
    var version: String?
    if let releases = try? report.nodes(forXPath: "//*[local-name()='releaseDetails']") {
      for release in releases {
        guard let element = release as? XMLElement,
          element.attribute(forName: "id")?.stringValue == "apps"
        else { continue }
        version = element.attribute(forName: "version")?.stringValue
      }
    }
    var failing: [ArchivalValidationResult.FailingRule] = []
    if let rules = try? report.nodes(forXPath: "//*[local-name()='rule']") {
      for rule in rules {
        guard let element = rule as? XMLElement,
          element.attribute(forName: "status")?.stringValue == "failed"
        else { continue }
        let specification = element.attribute(forName: "specification")?.stringValue ?? ""
        let clause = element.attribute(forName: "clause")?.stringValue ?? ""
        let failed = Int(element.attribute(forName: "failedChecks")?.stringValue ?? "") ?? 0
        let description =
          (try? element.nodes(forXPath: ".//*[local-name()='description']").first as? XMLElement)?
            .stringValue ?? ""
        failing.append(
          ArchivalValidationResult.FailingRule(
            specification: specification, clause: clause, description: description,
            failedChecks: failed))
      }
    }
    return ArchivalValidationResult(
      validator: validator, validatorVersion: version, profileName: profileName,
      isCompliant: isCompliant, passedRules: passedRules, failedRules: failedRules,
      failedChecks: failedChecks, failingRules: failing)
  }
}
