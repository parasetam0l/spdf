import Foundation
import PDFCore

// MARK: - A11Y-06 explicit PDF/UA output profile

public enum AccessibleOutputStandard: String, Sendable, CaseIterable, Equatable {
  case pdfUA1 = "PDF/UA-1"

  public var title: String { "PDF/UA-1 (ISO 14289-1)" }
  public var shortTitle: String { rawValue }

  public static let supportedStandards: [AccessibleOutputStandard] = [.pdfUA1]
  public static let unavailableStandards: [String] = [
    "PDF/UA-2 (ISO 14289-2) - not supported by this profile; never reported as validated.",
  ]

  public var summaryLine: String {
    "Declared profile: " + title + ". Supported standards: "
      + Self.supportedStandards.map(\.shortTitle).joined(separator: ", ")
      + ". Unsupported/unvalidated: PDF/UA-2."
  }
}

public struct AccessibleProfileRequirement: Sendable, Equatable, Identifiable {
  public enum Kind: String, Sendable, Equatable {
    case automaticRule
    case independentValidator
    case manualCheck
  }

  public let id: String
  public let title: String
  public let kind: Kind
  public let ruleID: String?
  public let required: Bool

  public init(
    id: String, title: String, kind: Kind, ruleID: String?, required: Bool = true
  ) {
    self.id = id
    self.title = title
    self.kind = kind
    self.ruleID = ruleID
    self.required = required
  }
}

public struct AccessibleOutputProfile: Sendable, Equatable {
  public let standard: AccessibleOutputStandard
  public let requirements: [AccessibleProfileRequirement]

  public init(standard: AccessibleOutputStandard = .pdfUA1) {
    self.standard = standard
    var requirements: [AccessibleProfileRequirement] = [
      .init(id: "req.structure", title: "Tagged structure tree", kind: .automaticRule, ruleID: "aa.structure.tree"),
      .init(id: "req.markinfo", title: "Marked content flag", kind: .automaticRule, ruleID: "aa.markinfo.marked"),
      .init(id: "req.pageTagging", title: "Page tagging", kind: .automaticRule, ruleID: "aa.page.marked"),
      .init(id: "req.mcid", title: "MCID uniqueness", kind: .automaticRule, ruleID: "aa.mcid.uniqueness"),
      .init(id: "req.parentTree", title: "ParentTree entries", kind: .automaticRule, ruleID: "aa.parenttree.entries"),
      .init(id: "req.language", title: "Document language", kind: .automaticRule, ruleID: "ua.language"),
      .init(id: "req.alt", title: "Figure alternate text", kind: .automaticRule, ruleID: "ua.figure.alt"),
      .init(id: "req.tableHeaders", title: "Table headers", kind: .automaticRule, ruleID: "ua.table.headers"),
      .init(id: "req.formNames", title: "Form field names", kind: .automaticRule, ruleID: "ua.form.names"),
      .init(id: "req.title", title: "Document title metadata", kind: .automaticRule, ruleID: "ua.metadata.title"),
      .init(id: "req.displayDocTitle", title: "DisplayDocTitle preference", kind: .automaticRule, ruleID: "ua.metadata.displayDocTitle"),
      .init(id: "req.uaIdentifier", title: "Declared PDF/UA XMP identifier", kind: .automaticRule, ruleID: "ua.metadata.xmpIdentifier"),
      .init(id: "req.independentValidator", title: "Independent PDF/UA validation", kind: .independentValidator, ruleID: "ua.independentValidator"),
    ]
    for rule in AccessibilityRuleCatalog.manualRules {
      requirements.append(
        AccessibleProfileRequirement(
          id: "req." + rule.id, title: rule.humanQuestion ?? rule.title,
          kind: .manualCheck, ruleID: rule.id))
    }
    self.requirements = requirements
  }

  public var summaryLines: [String] {
    var lines = [standard.summaryLine]
    lines.append(
      "Required metadata: document title (Info or XMP), XMP pdfuaid:part 1, "
        + "catalog /Lang and ViewerPreferences/DisplayDocTitle true.")
    lines.append(
      "Structure requirements: StructTreeRoot, MarkInfo/Marked, tagged pages, "
        + "ParentTree, unique MCIDs, figure /Alt and table headers.")
    lines.append(
      "Independent validation: veraPDF PDF/UA-1 must be run and the human checks must be "
        + "completed; otherwise the declared profile is not verified.")
    return lines
  }
}

public enum AccessibilityHumanCheckResult: String, Sendable, CaseIterable, Equatable {
  case notChecked
  case pass
  case fail

  public var title: String {
    switch self {
    case .notChecked: return "Not checked"
    case .pass: return "Pass"
    case .fail: return "Fail"
    }
  }
}

public struct AccessibleOutputHumanCheck: Sendable, Equatable, Identifiable {
  public var id: String { ruleID }
  public let ruleID: String
  public let question: String
  public let result: AccessibilityHumanCheckResult

  public init(
    ruleID: String, question: String, result: AccessibilityHumanCheckResult
  ) {
    self.ruleID = ruleID
    self.question = question
    self.result = result
  }
}

public enum AccessibleOutputVerdict: String, Sendable, Equatable {
  case pass
  case fail
  case notVerified

  public var title: String {
    switch self {
    case .pass: return "Pass"
    case .fail: return "Fail"
    case .notVerified: return "Not verified"
    }
  }
}

public struct AccessibleRequirementOutcome: Sendable, Equatable, Identifiable {
  public var id: String { requirement.id }
  public let requirement: AccessibleProfileRequirement
  public let status: AccessibilityRuleStatus
  public let detail: String
  public let remediationTools: [AccessibilityRemediationTool]

  public init(
    requirement: AccessibleProfileRequirement, status: AccessibilityRuleStatus,
    detail: String, remediationTools: [AccessibilityRemediationTool]
  ) {
    self.requirement = requirement
    self.status = status
    self.detail = detail
    self.remediationTools = remediationTools
  }
}

public struct AccessibleOutputConformanceReport: Sendable, Equatable {
  public let standard: AccessibleOutputStandard
  public let verdict: AccessibleOutputVerdict
  public let requirements: [AccessibleRequirementOutcome]
  public let navigableReport: AccessibilityNavigableReport
  public let independentValidator: ArchivalValidationResult?
  public let validatorUnavailableReason: String?
  public let humanChecks: [AccessibleOutputHumanCheck]
  public let requiredActions: [String]
  public let summaryLines: [String]

  public init(
    standard: AccessibleOutputStandard, verdict: AccessibleOutputVerdict,
    requirements: [AccessibleRequirementOutcome],
    navigableReport: AccessibilityNavigableReport,
    independentValidator: ArchivalValidationResult?,
    validatorUnavailableReason: String?,
    humanChecks: [AccessibleOutputHumanCheck], requiredActions: [String],
    summaryLines: [String]
  ) {
    self.standard = standard
    self.verdict = verdict
    self.requirements = requirements
    self.navigableReport = navigableReport
    self.independentValidator = independentValidator
    self.validatorUnavailableReason = validatorUnavailableReason
    self.humanChecks = humanChecks
    self.requiredActions = requiredActions
    self.summaryLines = summaryLines
  }

  public var passedRequirements: [AccessibleRequirementOutcome] {
    requirements.filter { $0.status == .pass }
  }

  public var failedRequirements: [AccessibleRequirementOutcome] {
    requirements.filter { $0.status == .fail }
  }

  public var unverifiedRequirements: [AccessibleRequirementOutcome] {
    requirements.filter { $0.status != .pass && $0.status != .fail }
  }

  public var validatorUnavailable: Bool { independentValidator == nil }

  public var report: String {
    var lines: [String] = []
    lines.append("sPDF Editor accessibility output profile (A11Y-06)")
    lines.append("Standard: " + standard.title)
    lines.append("Verdict: " + verdict.title)
    for line in summaryLines { lines.append(line) }
    lines.append("")
    lines.append("Profile requirements:")
    for outcome in requirements {
      lines.append(
        "  [\(outcome.status.title)] \(outcome.requirement.title): " + outcome.detail)
      for tool in outcome.remediationTools {
        lines.append("      remedy: " + tool.title + " - " + tool.routeHint)
      }
    }
    lines.append("")
    lines.append("Human checks:")
    for check in humanChecks {
      lines.append("  [\(check.result.title)] " + check.question)
    }
    if let validator = independentValidator {
      lines.append("")
      lines.append(validator.report())
    } else {
      lines.append("")
      lines.append(
        "Independent validator: unavailable - "
          + (validatorUnavailableReason ?? "no verdict was produced")
          + ". This is NOT a pass.")
    }
    lines.append("")
    lines.append("Underlying navigable report:")
    lines.append(contentsOf: navigableReport.report.components(separatedBy: "\n"))
    return lines.joined(separator: "\n") + "\n"
  }
}

// MARK: - A11Y-06 profile evaluation

public enum AccessibleOutputProfileValidation {
  /// The declared human-check list with current state (default not checked).
  public static func humanChecks(
    for profile: AccessibleOutputProfile,
    results: [String: AccessibilityHumanCheckResult] = [:]
  ) -> [AccessibleOutputHumanCheck] {
    profile.requirements.compactMap { requirement in
      guard requirement.kind == .manualCheck, let ruleID = requirement.ruleID,
        let rule = AccessibilityRuleCatalog.rule(id: ruleID)
      else { return nil }
      return AccessibleOutputHumanCheck(
        ruleID: ruleID, question: requirement.title,
        result: results[ruleID] ?? .notChecked)
    }
  }

  /// A11Y-06: evaluate the declared profile. A pass requires every required
  /// machine rule to pass, a compliant independent validator verdict and every
  /// human check passed. Missing validation, warnings or unchecked human items
  /// produce "not verified", never a pass.
  public static func evaluate(
    profile: AccessibleOutputProfile = AccessibleOutputProfile(),
    graph: PDFGraph, pageIDs: [PDFObjectID],
    humanCheckResults: [String: AccessibilityHumanCheckResult] = [:],
    independentValidator: ArchivalValidationResult? = nil,
    validatorUnavailableReason: String? = nil,
    limits: PDFLimits = PDFLimits()
  ) -> AccessibleOutputConformanceReport {
    let manualBooleans = humanCheckResults.compactMapValues { result -> Bool? in
      switch result {
      case .pass: return true
      case .fail: return false
      case .notChecked: return nil
      }
    }
    let navigable = AccessibilityReportBuilder.build(
      graph: graph, pageIDs: pageIDs, humanChecks: manualBooleans,
      independentValidator: independentValidator,
      validatorUnavailableReason: validatorUnavailableReason, limits: limits)
    var outcomes: [AccessibleRequirementOutcome] = []
    for requirement in profile.requirements {
      switch requirement.kind {
      case .manualCheck:
        guard let ruleID = requirement.ruleID,
          let rule = AccessibilityRuleCatalog.rule(id: ruleID)
        else {
          outcomes.append(
            AccessibleRequirementOutcome(
              requirement: requirement, status: .unavailable,
              detail: "No manual rule is registered; unavailable is not a pass.",
              remediationTools: [.humanReview]))
          continue
        }
        let result = humanCheckResults[ruleID] ?? .notChecked
        let status: AccessibilityRuleStatus
        let detail: String
        switch result {
        case .pass:
          status = .pass
          detail = "Human check passed."
        case .fail:
          status = .fail
          detail = "Human check failed."
        case .notChecked:
          status = .manual
          detail = "Not checked: " + (rule.humanQuestion ?? rule.title)
        }
        outcomes.append(
          AccessibleRequirementOutcome(
            requirement: requirement, status: status, detail: detail,
            remediationTools: [.humanReview]))
      case .independentValidator:
        if let validator = independentValidator {
          if validator.isCompliant {
            outcomes.append(
              AccessibleRequirementOutcome(
                requirement: requirement, status: .pass,
                detail: "\(validator.validator) reports compliance for \(validator.profileName).",
                remediationTools: [.independentValidator]))
          } else {
            outcomes.append(
              AccessibleRequirementOutcome(
                requirement: requirement, status: .fail,
                detail: "\(validator.validator) reports noncompliance "
                  + "(\(validator.failedRules) failed rule(s), \(validator.failedChecks) check(s)).",
                remediationTools: [.independentValidator]))
          }
        } else {
          outcomes.append(
            AccessibleRequirementOutcome(
              requirement: requirement, status: .unavailable,
              detail: "Independent validation unavailable: "
                + (validatorUnavailableReason ?? "no verdict was produced")
                + ". This is not a pass.",
              remediationTools: [.independentValidator]))
        }
      case .automaticRule:
        guard let ruleID = requirement.ruleID,
          let outcome = navigable.outcome(for: ruleID)
        else {
          outcomes.append(
            AccessibleRequirementOutcome(
              requirement: requirement, status: .unavailable,
              detail: "No rule result: unavailable is not a pass.",
              remediationTools: []))
          continue
        }
        outcomes.append(
          AccessibleRequirementOutcome(
            requirement: requirement, status: outcome.status,
            detail: outcome.detail,
            remediationTools: outcome.rule.remediationTools))
      }
    }
    let verdict: AccessibleOutputVerdict
    if outcomes.contains(where: { $0.status == .fail }) {
      verdict = .fail
    } else if outcomes.allSatisfy({ $0.status == .pass }) {
      verdict = .pass
    } else {
      verdict = .notVerified
    }
    var requiredActions: [String] = []
    for outcome in outcomes where outcome.status != .pass {
      let remedy = outcome.remediationTools.first.map {
        " — " + $0.title + " (" + $0.routeHint + ")"
      } ?? ""
      requiredActions.append(
        "\(outcome.requirement.title): \(outcome.status.title)\(remedy)")
    }
    let checks = humanChecks(for: profile, results: humanCheckResults)
    var summaryLines: [String] = []
    summaryLines.append(profile.standard.summaryLine)
    summaryLines.append(
      "Verdict: \(verdict.title). A pass requires every required rule to pass, a compliant "
        + "independent validator verdict, and every human check passed.")
    let automatic = outcomes.filter { $0.requirement.kind != .manualCheck }
    summaryLines.append(
      "Machine requirements: "
        + String(automatic.filter { $0.status == .pass }.count) + " pass, "
        + String(automatic.filter { $0.status == .fail }.count) + " fail, "
        + String(automatic.filter { $0.status != .pass && $0.status != .fail }.count)
        + " unverified.")
    let unchecked = checks.filter { $0.result == .notChecked }.count
    let failedChecks = checks.filter { $0.result == .fail }.count
    summaryLines.append(
      "Human checks: " + String(checks.count - unchecked - failedChecks) + " pass, "
        + String(failedChecks) + " fail, " + String(unchecked) + " not checked.")
    if validatorUnavailableReason != nil && independentValidator == nil {
      summaryLines.append("Independent validation is unavailable: NOT a pass.")
    }
    if let validator = independentValidator, !validator.isCompliant {
      summaryLines.append(
        "The independent validator returned noncompliance; the declared profile does not pass.")
    }
    if verdict != .pass {
      summaryLines.append(
        requiredActions.isEmpty
          ? "The declared profile is not verified."
          : "Required actions: " + requiredActions.joined(separator: "; "))
    }
    summaryLines.append(
      "Unsupported standard PDF/UA-2 is never represented as validated by this profile.")
    return AccessibleOutputConformanceReport(
      standard: profile.standard, verdict: verdict, requirements: outcomes,
      navigableReport: navigable, independentValidator: independentValidator,
      validatorUnavailableReason: validatorUnavailableReason, humanChecks: checks,
      requiredActions: requiredActions, summaryLines: summaryLines)
  }
}

// MARK: - A11Y-06 metadata/structure preparation

/// A11Y-06: complete the metadata and structure the declared PDF/UA-1 profile
/// requires. The command refuses when the document is not already tagged and
/// does not claim conformance: after writing the declared metadata it still
/// requires an independent validator verdict and the human checks.
public struct PrepareAccessibleProfileCommand: PDFEditCommand, Equatable, Sendable {
  public let standard: AccessibleOutputStandard
  public let title: String?
  public let language: String?

  public init(
    title: String? = nil, language: String? = nil,
    standard: AccessibleOutputStandard = .pdfUA1
  ) {
    self.standard = standard
    self.title = title
    self.language = language
  }

  public var name: String { "Complete PDF/UA Profile Metadata" }

  public func validate(in graph: PDFGraph) throws {
    let pageIDs = try PageTreeView(graph: graph).pages
    let inventory = try PDFStructureInspector.inspect(in: graph, pageIDs: pageIDs)
    guard inventory.rootObjectID != nil else {
      throw PDFError(
        .unsupported,
        "PDF/UA-1 requires an existing structure tree; tag the document before completing metadata")
    }
    guard inventory.hasMarkInfo else {
      throw PDFError(
        .unsupported, "PDF/UA-1 requires MarkInfo/Marked true; repairing structure is a reviewed action")
    }
    let resolvedLanguage =
      language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? inventory.language
    guard let resolvedLanguage, Self.validLanguageTag(resolvedLanguage) else {
      throw PDFError(
        .malformed,
        "PDF/UA-1 requires a document language (/Lang); provide a valid language tag such as en-US")
    }
    let resolvedTitle =
      title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? Self.existingTitle(in: graph)
    guard let resolvedTitle, !resolvedTitle.isEmpty, resolvedTitle.count <= 1_024 else {
      throw PDFError(
        .malformed,
        "PDF/UA-1 requires a document title; provide one or set it in metadata first")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    else {
      throw PDFError(.malformed, "The document catalog is missing")
    }
    let pageIDs = try PageTreeView(graph: graph).pages
    let inventory = try PDFStructureInspector.inspect(in: graph, pageIDs: pageIDs)
    let resolvedLanguage =
      language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? inventory.language ?? ""
    let resolvedTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? Self.existingTitle(in: graph) ?? "")
    // ViewerPreferences: preserve existing keys and set DisplayDocTitle true.
    var preferences: [PDFName: PDFValue] = [:]
    if let value = catalog[PDFName("ViewerPreferences")] {
      switch value {
      case .dictionary(let dictionary):
        preferences = dictionary
      case .reference(let id):
        if case .dictionary(let dictionary)? = graph.objects[id] {
          preferences = dictionary
        }
      default:
        break
      }
    }
    preferences[PDFName("DisplayDocTitle")] = .boolean(true)
    catalog[PDFName("ViewerPreferences")] = .dictionary(preferences)
    if !resolvedLanguage.isEmpty {
      catalog[PDFName("Lang")] = .string(AnnotationText.encode(resolvedLanguage))
    }
    // Document title: update the existing info dictionary or create one.
    var info: [PDFName: PDFValue] = [:]
    if case .reference(let infoID)? = graph.trailer[PDFName("Info")],
      case .dictionary(let existing)? = graph.objects[infoID]
    {
      info = existing
      info[PDFName("Title")] = .string(AnnotationText.encode(resolvedTitle))
      graph.objects[infoID] = .dictionary(info)
    } else {
      info[PDFName("Title")] = .string(AnnotationText.encode(resolvedTitle))
      let infoID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
      graph.objects[infoID] = .dictionary(info)
      graph.trailer[PDFName("Info")] = .reference(infoID)
    }
    // A deterministic minimal XMP packet carrying the declared PDF/UA-1 id.
    let xmp = Self.xmpPacket(title: resolvedTitle, language: resolvedLanguage)
    let xmpBytes = Data(xmp.utf8)
    let metadataID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    graph.objects[metadataID] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("Metadata")),
          PDFName("Subtype"): .name(PDFName("XML")),
          PDFName("Length"): .integer(Int64(xmpBytes.count)),
        ], bytes: xmpBytes))
    catalog[PDFName("Metadata")] = .reference(metadataID)
    graph.objects[catalogID] = .dictionary(catalog)
    return graph
  }

  public static func existingTitle(in graph: PDFGraph) -> String? {
    if case .reference(let infoID)? = graph.trailer[PDFName("Info")],
      case .dictionary(let info)? = graph.objects[infoID],
      case .string(let data)? = info[PDFName("Title")]
    {
      let decoded = AnnotationText.decode(data)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !decoded.isEmpty { return decoded }
    }
    if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID],
      case .reference(let metadataID)? = catalog[PDFName("Metadata")],
      case .stream(let stream)? = graph.objects[metadataID],
      let xmp = String(bytes: stream.bytes, encoding: .utf8)
    {
      return AccessibilityReportBuilder.extractTitleFromXMP(xmp)
    }
    return nil
  }

  static func validLanguageTag(_ tag: String) -> Bool {
    guard (2...35).contains(tag.count) else { return false }
    return tag.unicodeScalars.allSatisfy { scalar in
      CharacterSet.alphanumerics.contains(scalar) || scalar == "-"
    }
  }

  static func xmpPacket(title: String, language: String) -> String {
    let escapedTitle = title
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
    let escapedLanguage = language
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
    return """
      <?xpacket begin="\u{feff}" id="W5M0MpCehiHzreSzNTczkc9d"?>
      <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:pdfuaid="http://www.aiim.org/pdfua/ns/id/">
            <dc:title>
              <rdf:Alt>
                <rdf:li xml:lang="x-default">\(escapedTitle)</rdf:li>
              </rdf:Alt>
            </dc:title>
            <dc:language>
              <rdf:Bag>
                <rdf:li>\(escapedLanguage)</rdf:li>
              </rdf:Bag>
            </dc:language>
            <pdfuaid:part>1</pdfuaid:part>
          </rdf:Description>
        </rdf:RDF>
      </x:xmpmeta>
      <?xpacket end="w"?>

      """
  }
}
