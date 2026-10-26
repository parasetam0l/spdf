import Foundation
import PDFCore

// MARK: - A11Y-05 navigable accessibility report

public enum AccessibilityCheckMode: String, Sendable, CaseIterable, Equatable {
  case automatic
  case manual

  public var title: String { self == .automatic ? "Automatic" : "Manual check" }
}

public enum AccessibilityRuleStatus: String, Sendable, CaseIterable, Equatable {
  case pass
  case warning
  case fail
  case manual
  case unavailable

  public var title: String {
    switch self {
    case .pass: return "Pass"
    case .warning: return "Warning"
    case .fail: return "Fail"
    case .manual: return "Manual check needed"
    case .unavailable: return "Unavailable"
    }
  }
}

public enum AccessibilityRemediationTool: String, Sendable, CaseIterable, Equatable {
  case structureInspector
  case taggingAssistant
  case alternateText
  case tableHeaders
  case formDesign
  case formsSidebar
  case documentMetadata
  case pageOrganizer
  case prepareUAProfile
  case independentValidator
  case humanReview

  public var title: String {
    switch self {
    case .structureInspector: return "Structure inspector"
    case .taggingAssistant: return "Tagging assistant"
    case .alternateText: return "Alternate text"
    case .tableHeaders: return "Table header scope"
    case .formDesign: return "Form design"
    case .formsSidebar: return "Forms sidebar"
    case .documentMetadata: return "Document metadata"
    case .pageOrganizer: return "Page organizer"
    case .prepareUAProfile: return "Complete PDF/UA metadata"
    case .independentValidator: return "Independent validator"
    case .humanReview: return "Human review checklist"
    }
  }

  public var routeHint: String {
    switch self {
    case .structureInspector: return "View > Show Structure (structure sidebar)"
    case .taggingAssistant: return "Annotate > Tag Document / review suggestions"
    case .alternateText: return "Structure sidebar > Figure > Edit Alternate Text"
    case .tableHeaders: return "Structure sidebar > Table > Header Scope"
    case .formDesign: return "Form > Form Design"
    case .formsSidebar: return "View > Forms"
    case .documentMetadata: return "File > Document Metadata (title/language)"
    case .pageOrganizer: return "Page > Organize Pages"
    case .prepareUAProfile: return "Accessibility Report > Complete PDF/UA Metadata"
    case .independentValidator: return "Accessibility Report > Run Independent Validator"
    case .humanReview: return "Accessibility Report > Human checks"
    }
  }

  public var commandHint: String? {
    switch self {
    case .alternateText: return "SetStructureAltTextCommand"
    case .tableHeaders: return "SetTableHeaderScopeCommand"
    case .prepareUAProfile: return "PrepareAccessibleProfileCommand"
    default: return nil
    }
  }
}

public struct AccessibilityObjectReference: Sendable, Equatable, Identifiable {
  public enum Kind: String, Sendable, CaseIterable, Equatable {
    case structureElement
    case page
    case catalog
    case formField
    case contentStream
    case metadata
    case independentValidator
  }

  public let kind: Kind
  public let label: String
  public let objectID: PDFObjectID?
  public let pageIndex: Int?
  public let role: String?
  public let fieldName: String?
  public let detail: String?

  public var id: String {
    kind.rawValue + "/" + (objectID.map { String($0.number) } ?? "-")
      + "/" + String(pageIndex ?? -1) + "/" + label
  }

  public init(
    kind: Kind, label: String, objectID: PDFObjectID? = nil, pageIndex: Int? = nil,
    role: String? = nil, fieldName: String? = nil, detail: String? = nil
  ) {
    self.kind = kind
    self.label = label
    self.objectID = objectID
    self.pageIndex = pageIndex
    self.role = role
    self.fieldName = fieldName
    self.detail = detail
  }

  public var navigationLine: String {
    var parts: [String] = [label]
    if let pageIndex { parts.append("page " + String(pageIndex + 1)) }
    if let role { parts.append("role " + role) }
    if let fieldName { parts.append("field " + fieldName) }
    if let objectID { parts.append("object " + String(objectID.number)) }
    return parts.joined(separator: ", ")
  }
}

public struct AccessibilityRuleDefinition: Sendable, Equatable, Identifiable {
  public let id: String
  public let title: String
  public let summary: String
  public let mode: AccessibilityCheckMode
  public let auditRuleNames: [String]
  public let remediationTools: [AccessibilityRemediationTool]
  public let objectKind: AccessibilityObjectReference.Kind
  public let testedPassCase: String
  public let testedFailCase: String
  public let humanQuestion: String?

  public var isClaimed: Bool { !testedPassCase.isEmpty && !testedFailCase.isEmpty }

  public init(
    id: String, title: String, summary: String, mode: AccessibilityCheckMode,
    auditRuleNames: [String] = [], remediationTools: [AccessibilityRemediationTool],
    objectKind: AccessibilityObjectReference.Kind, testedPassCase: String,
    testedFailCase: String, humanQuestion: String? = nil
  ) {
    self.id = id
    self.title = title
    self.summary = summary
    self.mode = mode
    self.auditRuleNames = auditRuleNames
    self.remediationTools = remediationTools
    self.objectKind = objectKind
    self.testedPassCase = testedPassCase
    self.testedFailCase = testedFailCase
    self.humanQuestion = humanQuestion
  }
}

public enum AccessibilityRuleCatalog {
  public static let automaticRules: [AccessibilityRuleDefinition] = [
    AccessibilityRuleDefinition(
      id: "aa.structure.tree", title: "Structure tree",
      summary: "The document has a StructTreeRoot and tagged content.",
      mode: .automatic, auditRuleNames: ["Structure tree"],
      remediationTools: [.structureInspector, .taggingAssistant],
      objectKind: .catalog,
      testedPassCase: "tagged fixture with a StructTreeRoot reports no structure error",
      testedFailCase: "untagged one-page fixture reports Structure tree error"),
    AccessibilityRuleDefinition(
      id: "aa.markinfo.marked", title: "Marked content flag",
      summary: "MarkInfo/Marked is true when a structure tree exists.",
      mode: .automatic, auditRuleNames: ["Marked content"],
      remediationTools: [.structureInspector],
      objectKind: .catalog,
      testedPassCase: "tagged fixture sets MarkInfo/Marked true",
      testedFailCase: "structure root without MarkInfo reports Marked content error"),
    AccessibilityRuleDefinition(
      id: "aa.page.marked", title: "Page tagging",
      summary: "Every page carries marked content and StructParents.",
      mode: .automatic, auditRuleNames: ["Page tagging"],
      remediationTools: [.structureInspector, .taggingAssistant],
      objectKind: .page,
      testedPassCase: "tagged fixture pages carry marked content",
      testedFailCase: "page without marked content reports Page tagging error"),
    AccessibilityRuleDefinition(
      id: "aa.mcid.uniqueness", title: "MCID uniqueness",
      summary: "Marked-content IDs are unique per page.",
      mode: .automatic, auditRuleNames: ["MCID uniqueness"],
      remediationTools: [.structureInspector, .taggingAssistant],
      objectKind: .page,
      testedPassCase: "tagged fixture uses distinct MCIDs",
      testedFailCase: "duplicate MCID fixture reports MCID uniqueness error"),
    AccessibilityRuleDefinition(
      id: "aa.parenttree.entries", title: "ParentTree",
      summary: "StructParents declarations resolve to ParentTree entries.",
      mode: .automatic, auditRuleNames: ["ParentTree"],
      remediationTools: [.structureInspector],
      objectKind: .catalog,
      testedPassCase: "tagged fixture resolves its ParentTree",
      testedFailCase: "StructParents without ParentTree entry reports ParentTree error"),
    AccessibilityRuleDefinition(
      id: "ua.language", title: "Catalog language",
      summary: "The catalog declares the document language (/Lang).",
      mode: .automatic, auditRuleNames: ["Language"],
      remediationTools: [.documentMetadata],
      objectKind: .catalog,
      testedPassCase: "tagged fixture with /Lang passes language presence",
      testedFailCase: "missing /Lang reports the language warning"),
    AccessibilityRuleDefinition(
      id: "ua.figure.alt", title: "Figure alternate text",
      summary: "Figure structure elements carry /Alt text.",
      mode: .automatic, auditRuleNames: ["Figure alternate text"],
      remediationTools: [.structureInspector, .alternateText],
      objectKind: .structureElement,
      testedPassCase: "figure element with /Alt reports info only",
      testedFailCase: "figure element without /Alt reports an error"),
    AccessibilityRuleDefinition(
      id: "ua.table.headers", title: "Table headers",
      summary: "Table structures include TH header cells.",
      mode: .automatic, auditRuleNames: ["Table headers"],
      remediationTools: [.structureInspector, .tableHeaders],
      objectKind: .structureElement,
      testedPassCase: "table with TH reports info",
      testedFailCase: "table without TH reports the header warning"),
    AccessibilityRuleDefinition(
      id: "ua.form.names", title: "Form field names",
      summary: "Form fields have non-empty names.",
      mode: .automatic, auditRuleNames: ["Form field names"],
      remediationTools: [.formsSidebar, .formDesign],
      objectKind: .formField,
      testedPassCase: "named form fields report info",
      testedFailCase: "unnamed form field reports a Form field names error"),
    AccessibilityRuleDefinition(
      id: "ua.metadata.title", title: "Document title",
      summary: "A document title exists in Info or XMP metadata.",
      mode: .automatic,
      remediationTools: [.documentMetadata, .prepareUAProfile],
      objectKind: .metadata,
      testedPassCase: "document with /Title or dc:title passes",
      testedFailCase: "document without any title reports an error"),
    AccessibilityRuleDefinition(
      id: "ua.metadata.displayDocTitle", title: "DisplayDocTitle",
      summary: "ViewerPreferences/DisplayDocTitle is true so the title is shown.",
      mode: .automatic,
      remediationTools: [.documentMetadata, .prepareUAProfile],
      objectKind: .catalog,
      testedPassCase: "ViewerPreferences DisplayDocTitle true passes",
      testedFailCase: "absent/false DisplayDocTitle reports an error"),
    AccessibilityRuleDefinition(
      id: "ua.metadata.xmpIdentifier", title: "PDF/UA identifier",
      summary: "A declared PDF/UA identifier is present in XMP metadata.",
      mode: .automatic,
      remediationTools: [.prepareUAProfile],
      objectKind: .metadata,
      testedPassCase: "XMP with pdfuaid:part 1 passes",
      testedFailCase: "XMP without the identifier reports an error"),
    AccessibilityRuleDefinition(
      id: "ua.independentValidator", title: "Independent validator",
      summary: "An independent PDF/UA validator was run and returned a verdict.",
      mode: .automatic,
      remediationTools: [.independentValidator],
      objectKind: .independentValidator,
      testedPassCase: "validator compliant verdict",
      testedFailCase: "validator unavailable is never a pass; noncompliant verdict fails"),
    AccessibilityRuleDefinition(
      id: "ua.render.evidence", title: "Rendering evidence",
      summary: "Rendering success is not evidence of accessibility.",
      mode: .automatic, auditRuleNames: ["Rendering"],
      remediationTools: [.humanReview],
      objectKind: .catalog,
      testedPassCase: "rendering context is reported without claiming accessibility",
      testedFailCase: "rendering alone never passes a human-review requirement"),
  ]

  public static let manualRules: [AccessibilityRuleDefinition] = {
    let tools: [AccessibilityRemediationTool] = [.humanReview]
    let questions = PDFAccessibilityAudit.humanReviewChecklist
    let ids = [
      "manual.altQuality", "manual.readingOrder", "manual.contrast", "manual.linkPurpose",
      "manual.tableStructure", "manual.scanText", "manual.formUnderstanding",
    ]
    var rules = zip(ids, questions).map { id, question in
      AccessibilityRuleDefinition(
        id: id, title: question.split(separator: ".").first.map(String.init) ?? id,
        summary: question, mode: .manual, remediationTools: tools,
        objectKind: .page, testedPassCase: "human check marked pass",
        testedFailCase: "human check marked fail", humanQuestion: question)
    }
    rules.append(
      AccessibilityRuleDefinition(
        id: "aa.form.semantics", title: "Form semantics",
        summary: "Field descriptions and fill behavior are understandable.",
        mode: .manual, auditRuleNames: ["Form semantics"],
        remediationTools: [.formDesign, .humanReview],
        objectKind: .formField,
        testedPassCase: "human check marked pass",
        testedFailCase: "human check marked fail",
        humanQuestion: PDFAccessibilityAudit.humanReviewChecklist[6]))
    return rules
  }()

  public static var allRules: [AccessibilityRuleDefinition] { automaticRules + manualRules }

  public static func rule(id: String) -> AccessibilityRuleDefinition? {
    allRules.first { $0.id == id }
  }

  public static func rule(forAuditRule name: String) -> AccessibilityRuleDefinition? {
    automaticRules.first { $0.auditRuleNames.contains(name) }
  }
}

// MARK: - Findings and report

/// A11Y-05: one navigable finding with affected objects and remediation tools.
public struct AccessibilityNavigableFinding: Sendable, Equatable, Identifiable {
  public let id: String
  public let ruleID: String
  public let ruleTitle: String
  public let severity: PDFAccessibilityAudit.Finding.Severity
  public let detail: String
  public let mode: AccessibilityCheckMode
  public let objects: [AccessibilityObjectReference]
  public let remediationTools: [AccessibilityRemediationTool]

  public init(
    id: String, ruleID: String, ruleTitle: String,
    severity: PDFAccessibilityAudit.Finding.Severity, detail: String,
    mode: AccessibilityCheckMode, objects: [AccessibilityObjectReference],
    remediationTools: [AccessibilityRemediationTool]
  ) {
    self.id = id
    self.ruleID = ruleID
    self.ruleTitle = ruleTitle
    self.severity = severity
    self.detail = detail
    self.mode = mode
    self.objects = objects
    self.remediationTools = remediationTools
  }

  public var remediationHints: [String] {
    remediationTools.map { $0.title + " — " + $0.routeHint }
  }
}

public struct AccessibilityRuleOutcome: Sendable, Equatable, Identifiable {
  public var id: String { rule.id }
  public let rule: AccessibilityRuleDefinition
  public let status: AccessibilityRuleStatus
  public let detail: String
  public let findings: [AccessibilityNavigableFinding]
  public let objects: [AccessibilityObjectReference]

  public init(
    rule: AccessibilityRuleDefinition, status: AccessibilityRuleStatus, detail: String,
    findings: [AccessibilityNavigableFinding],
    objects: [AccessibilityObjectReference]
  ) {
    self.rule = rule
    self.status = status
    self.detail = detail
    self.findings = findings
    self.objects = objects
  }
}

/// A11Y-05: the navigable report. Automatic results are kept separate from
/// manual checks, every finding is linked to objects and remediation tools, and
/// the report records exactly which rules a rerun covered.
public struct AccessibilityNavigableReport: Sendable, Equatable {
  public let outcomes: [AccessibilityRuleOutcome]
  public let findings: [AccessibilityNavigableFinding]
  public let rerunRuleIDs: [String]
  public let independentValidator: ArchivalValidationResult?
  public let validatorUnavailableReason: String?
  public let humanChecks: [String: Bool]
  public let summaryLines: [String]

  public init(
    outcomes: [AccessibilityRuleOutcome],
    findings: [AccessibilityNavigableFinding],
    rerunRuleIDs: [String],
    independentValidator: ArchivalValidationResult?,
    validatorUnavailableReason: String?,
    humanChecks: [String: Bool],
    summaryLines: [String]
  ) {
    self.outcomes = outcomes
    self.findings = findings
    self.rerunRuleIDs = rerunRuleIDs
    self.independentValidator = independentValidator
    self.validatorUnavailableReason = validatorUnavailableReason
    self.humanChecks = humanChecks
    self.summaryLines = summaryLines
  }

  public var automaticOutcomes: [AccessibilityRuleOutcome] {
    outcomes.filter { $0.rule.mode == .automatic }
  }

  public var manualOutcomes: [AccessibilityRuleOutcome] {
    outcomes.filter { $0.rule.mode == .manual }
  }

  public var failures: [AccessibilityRuleOutcome] {
    outcomes.filter { $0.status == .fail }
  }

  public var warnings: [AccessibilityRuleOutcome] {
    outcomes.filter { $0.status == .warning }
  }

  public var unavailableChecks: [AccessibilityRuleOutcome] {
    outcomes.filter { $0.status == .unavailable }
  }

  public var pendingManualChecks: [AccessibilityRuleOutcome] {
    manualOutcomes.filter { $0.status == .manual }
  }

  public var isAutomaticPass: Bool {
    !outcomes.contains {
      $0.rule.mode == .automatic && ($0.status == .fail || $0.status == .warning)
    }
  }

  public func outcome(for ruleID: String) -> AccessibilityRuleOutcome? {
    outcomes.first { $0.rule.id == ruleID }
  }

  public var report: String {
    var lines: [String] = []
    lines.append("sPDF Editor navigable accessibility report (A11Y-05)")
    lines.append(
      "Rules: \(outcomes.count) evaluated"
        + (rerunRuleIDs.isEmpty ? "" : " (rerun only: \(rerunRuleIDs.joined(separator: ", ")))")
        + "; automatic: \(automaticOutcomes.count); manual: \(manualOutcomes.count).")
    for line in summaryLines { lines.append(line) }
    lines.append("")
    lines.append("Rule results:")
    for outcome in outcomes {
      lines.append(
        "  [\(outcome.status.title)] \(outcome.rule.id) - \(outcome.rule.title): "
          + outcome.detail)
      for object in outcome.objects {
        lines.append("      affected: " + object.navigationLine)
      }
      for finding in outcome.findings {
        lines.append("      finding: " + finding.detail)
        for hint in finding.remediationHints { lines.append("      remedy: " + hint) }
      }
      if outcome.status == .manual {
        lines.append("      manual check required; no automated verdict was inferred.")
      }
      if outcome.status == .unavailable {
        lines.append("      unavailable is NOT a pass.")
      }
    }
    lines.append("")
    lines.append(
      "Every claimed automatic rule has documented tested pass/fail cases; each finding "
        + "names the affected object and the remediation tool. Manual checks are never "
        + "reported as passed by automation.")
    lines.append("")
    if let validator = independentValidator {
      lines.append(validator.report())
    } else {
      lines.append(
        "Independent validator: unavailable - "
          + (validatorUnavailableReason ?? "no verdict was produced")
          + ". This is NOT a pass.")
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

// MARK: - Evidence and evaluation

public enum AccessibilityReportBuilder {
  struct Evidence {
    let graph: PDFGraph
    let pageIDs: [PDFObjectID]
    let inventory: PDFStructureInventory
    let audit: PDFAccessibilityAudit
    let fields: [FormField]
    let catalog: [PDFName: PDFValue]?
    let catalogID: PDFObjectID?
    let documentTitle: String?
    let displayDocTitle: Bool
    let xmpText: String?
    let xmpObjectID: PDFObjectID?
    let validator: ArchivalValidationResult?
    let validatorUnavailableReason: String?
    let humanChecks: [String: Bool]
  }

  /// A11Y-05: build the full navigable report.
  public static func build(
    graph: PDFGraph, pageIDs: [PDFObjectID],
    humanChecks: [String: Bool] = [:],
    independentValidator: ArchivalValidationResult? = nil,
    validatorUnavailableReason: String? = nil,
    limits: PDFLimits = PDFLimits()
  ) -> AccessibilityNavigableReport {
    let evidence = makeEvidence(
      graph: graph, pageIDs: pageIDs, humanChecks: humanChecks,
      validator: independentValidator,
      validatorUnavailableReason: validatorUnavailableReason, limits: limits)
    return build(evidence: evidence, ruleIDs: nil, rerunRuleIDs: [])
  }

  /// A11Y-05: rerun only the affected checks. Only the selected rules are
  /// evaluated; the report records the selected rule ids and says other results
  /// are not included.
  public static func rerun(
    ruleIDs: [String], graph: PDFGraph, pageIDs: [PDFObjectID],
    humanChecks: [String: Bool] = [:],
    independentValidator: ArchivalValidationResult? = nil,
    validatorUnavailableReason: String? = nil,
    limits: PDFLimits = PDFLimits()
  ) -> AccessibilityNavigableReport {
    let selected = ruleIDs.filter { AccessibilityRuleCatalog.rule(id: $0) != nil }
    let evidence = makeEvidence(
      graph: graph, pageIDs: pageIDs, humanChecks: humanChecks,
      validator: independentValidator,
      validatorUnavailableReason: validatorUnavailableReason, limits: limits)
    return build(
      evidence: evidence, ruleIDs: Set(selected), rerunRuleIDs: selected)
  }

  // MARK: Evidence

  static func makeEvidence(
    graph: PDFGraph, pageIDs: [PDFObjectID], humanChecks: [String: Bool],
    validator: ArchivalValidationResult?, validatorUnavailableReason: String?,
    limits: PDFLimits
  ) -> Evidence {
    let inventory = (try? PDFStructureInspector.inspect(
      in: graph, pageIDs: pageIDs, limits: limits))
      ?? PDFStructureInventory(
        rootObjectID: nil, roleMap: [:], classMap: [:], elements: [],
        parentTreeKeys: [], pageStructParents: [], pageMCIDs: [], issues: [],
        hasMarkInfo: false, language: nil, isTagged: false)
    let audit = PDFAccessibilityAudit.audit(graph, pageIDs: pageIDs, limits: limits)
    let fields = (try? FormInventory.fields(in: graph, pageIDs: pageIDs)) ?? []
    let catalog = catalogDictionary(in: graph)
    let catalogID: PDFObjectID? = {
      if case .reference(let id)? = graph.trailer[PDFName("Root")] { return id }
      return nil
    }()
    let info = infoDictionary(in: graph)
    var title: String?
    if let info, case .string(let data)? = info[PDFName("Title")] {
      let decoded = AnnotationText.decode(data)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !decoded.isEmpty { title = decoded }
    }
    var xmpText: String?
    var xmpObjectID: PDFObjectID?
    if let catalog, let value = catalog[PDFName("Metadata")] {
      switch value {
      case .reference(let id):
        if case .stream(let stream)? = graph.objects[id] {
          xmpText = String(decoding: stream.bytes, as: UTF8.self)
          xmpObjectID = id
        }
      case .stream(let stream):
        xmpText = String(decoding: stream.bytes, as: UTF8.self)
      default:
        break
      }
    }
    if title == nil, let xmpText, let match = extractTitleFromXMP(xmpText) {
      title = match
    }
    let displayDocTitle = viewerDisplayDocTitle(catalog: catalog, graph: graph)
    return Evidence(
      graph: graph, pageIDs: pageIDs, inventory: inventory, audit: audit,
      fields: fields, catalog: catalog, catalogID: catalogID, documentTitle: title,
      displayDocTitle: displayDocTitle, xmpText: xmpText, xmpObjectID: xmpObjectID,
      validator: validator, validatorUnavailableReason: validatorUnavailableReason,
      humanChecks: humanChecks)
  }

  // MARK: Evaluation

  static func build(
    evidence: Evidence, ruleIDs: Set<String>?, rerunRuleIDs: [String]
  ) -> AccessibilityNavigableReport {
    let rules = AccessibilityRuleCatalog.allRules
    let selected = rules.filter { ruleIDs == nil || ruleIDs!.contains($0.id) }
    var outcomes: [AccessibilityRuleOutcome] = []
    for rule in selected {
      outcomes.append(evaluate(rule: rule, evidence: evidence))
    }
    let findings = outcomes.flatMap(\.findings)
    var summaryLines: [String] = []
    let failures = outcomes.filter { $0.status == .fail }.count
    let warnings = outcomes.filter { $0.status == .warning }.count
    let manual = outcomes.filter { $0.status == .manual }.count
    let unavailable = outcomes.filter { $0.status == .unavailable }.count
    let passes = outcomes.filter { $0.status == .pass }.count
    summaryLines.append(
      "Automatic results: \(passes) pass, \(warnings) warning, \(failures) fail, "
        + "\(unavailable) unavailable. Manual checks: \(manual) still require a human decision.")
    if ruleIDs != nil {
      summaryLines.append(
        "Rerun limited to affected checks: " + rerunRuleIDs.joined(separator: ", ")
          + ". Other rule results are not included in this report.")
    }
    if unavailable > 0 {
      summaryLines.append("At least one check is unavailable; unavailable is never a pass.")
    }
    return AccessibilityNavigableReport(
      outcomes: outcomes, findings: findings, rerunRuleIDs: rerunRuleIDs,
      independentValidator: evidence.validator,
      validatorUnavailableReason: evidence.validatorUnavailableReason,
      humanChecks: evidence.humanChecks, summaryLines: summaryLines)
  }

  static func evaluate(
    rule: AccessibilityRuleDefinition, evidence: Evidence
  ) -> AccessibilityRuleOutcome {
    if rule.mode == .manual {
      let status: AccessibilityRuleStatus
      let detail: String
      if let passed = evidence.humanChecks[rule.id] {
        status = passed ? .pass : .fail
        detail = passed ? "Human check marked passed." : "Human check marked failed."
      } else {
        status = .manual
        detail = rule.humanQuestion ?? rule.summary
      }
      return AccessibilityRuleOutcome(
        rule: rule, status: status, detail: detail, findings: [], objects: [])
    }
    switch rule.id {
    case "aa.structure.tree":
      return outcomeFor(
        rule: rule, evidence: evidence, auditNames: ["Structure tree"],
        objects: catalogObject(evidence))
    case "aa.markinfo.marked":
      return outcomeFor(
        rule: rule, evidence: evidence, auditNames: ["Marked content"],
        objects: catalogObject(evidence))
    case "aa.page.marked":
      return outcomeFor(
        rule: rule, evidence: evidence, auditNames: ["Page tagging"],
        objects: pageIssueObjects(evidence, kinds: [.unmarkedPage]))
    case "aa.mcid.uniqueness":
      return outcomeFor(
        rule: rule, evidence: evidence, auditNames: ["MCID uniqueness"],
        objects: pageIssueObjects(evidence, kinds: [.duplicateMCID]))
    case "aa.parenttree.entries":
      return outcomeFor(
        rule: rule, evidence: evidence, auditNames: ["ParentTree"],
        objects: pageIssueObjects(evidence, kinds: [.missingParentTreeEntry]))
    case "ua.language":
      return outcomeFor(
        rule: rule, evidence: evidence, auditNames: ["Language"],
        objects: catalogObject(evidence))
    case "ua.figure.alt":
      let figures = evidence.inventory.elements.filter { $0.role == "Figure" }
      let objects = figures.map { element in
        AccessibilityObjectReference(
          kind: .structureElement, label: element.title ?? "Figure",
          objectID: element.objectID, pageIndex: element.pageIndex, role: element.role,
          detail: (element.alt ?? "").isEmpty ? "missing /Alt" : "has /Alt")
      }
      return outcomeFor(
        rule: rule, evidence: evidence, auditNames: ["Figure alternate text"],
        objects: objects)
    case "ua.table.headers":
      let tables = evidence.inventory.elements.filter { $0.role == "Table" }
      let objects = tables.map { element in
        AccessibilityObjectReference(
          kind: .structureElement, label: element.title ?? "Table",
          objectID: element.objectID, pageIndex: element.pageIndex, role: element.role)
      }
      return outcomeFor(
        rule: rule, evidence: evidence, auditNames: ["Table headers"], objects: objects)
    case "ua.form.names":
      let objects = evidence.fields.map { field in
        AccessibilityObjectReference(
          kind: .formField, label: field.name.isEmpty ? "unnamed field" : field.name,
          objectID: field.fieldID,
          pageIndex: field.widgets.first(where: { $0.pageIndex != nil })?.pageIndex,
          fieldName: field.name)
      }
      return outcomeFor(
        rule: rule, evidence: evidence, auditNames: ["Form field names"],
        objects: objects)
    case "ua.render.evidence":
      return outcomeFor(
        rule: rule, evidence: evidence, auditNames: ["Rendering"],
        objects: catalogObject(evidence))
    case "aa.form.semantics":
      return AccessibilityRuleOutcome(
        rule: rule, status: .manual, detail: rule.humanQuestion ?? rule.summary,
        findings: [], objects: [])
    case "ua.metadata.title":
      let objects = metadataObjects(evidence)
      if let title = evidence.documentTitle {
        return AccessibilityRuleOutcome(
          rule: rule, status: .pass, detail: "Document title: \(title).",
          findings: [], objects: objects)
      }
      return AccessibilityRuleOutcome(
        rule: rule, status: .fail,
        detail: "No document title in Info /Title or XMP dc:title.",
        findings: [
          finding(
            rule: rule, severity: .error,
            detail: "No document title is present in metadata.", objects: objects)
        ], objects: objects)
    case "ua.metadata.displayDocTitle":
      let objects = catalogObject(evidence)
      if evidence.displayDocTitle {
        return AccessibilityRuleOutcome(
          rule: rule, status: .pass, detail: "ViewerPreferences DisplayDocTitle is true.",
          findings: [], objects: objects)
      }
      return AccessibilityRuleOutcome(
        rule: rule, status: .fail,
        detail: "ViewerPreferences/DisplayDocTitle is absent or false.",
        findings: [
          finding(
            rule: rule, severity: .error,
            detail: "DisplayDocTitle must be true so the document title is presented.",
            objects: objects)
        ], objects: objects)
    case "ua.metadata.xmpIdentifier":
      let objects = metadataObjects(evidence)
      if let xmp = evidence.xmpText, hasPDFUAIdentifier(xmp) {
        return AccessibilityRuleOutcome(
          rule: rule, status: .pass, detail: "XMP declares the PDF/UA identifier.",
          findings: [], objects: objects)
      }
      return AccessibilityRuleOutcome(
        rule: rule, status: .fail,
        detail: "XMP metadata does not declare a PDF/UA identifier.",
        findings: [
          finding(
            rule: rule, severity: .error,
            detail: "No pdfuaid:part identifier is present in XMP metadata.",
            objects: objects)
        ], objects: objects)
    case "ua.independentValidator":
      if let validator = evidence.validator {
        if validator.isCompliant {
          return AccessibilityRuleOutcome(
            rule: rule, status: .pass,
            detail: "\(validator.validator) reports compliance for \(validator.profileName).",
            findings: [], objects: [])
        }
        return AccessibilityRuleOutcome(
          rule: rule, status: .fail,
          detail: "\(validator.validator) reports noncompliance "
            + "(\(validator.failedRules) failed rule(s), \(validator.failedChecks) check(s)).",
          findings: [
            finding(
              rule: rule, severity: .error,
              detail: "Independent validator verdict: not compliant.", objects: [])
          ], objects: [])
      }
      return AccessibilityRuleOutcome(
        rule: rule, status: .unavailable,
        detail: "Independent validator unavailable: "
          + (evidence.validatorUnavailableReason ?? "no verdict was produced")
          + ". This is not a pass.",
        findings: [], objects: [])
    default:
      return AccessibilityRuleOutcome(
        rule: rule, status: .unavailable,
        detail: "No evaluator is registered for this rule; unavailable is not a pass.",
        findings: [], objects: [])
    }
  }

  static func outcomeFor(
    rule: AccessibilityRuleDefinition, evidence: Evidence, auditNames: [String],
    objects: [AccessibilityObjectReference]
  ) -> AccessibilityRuleOutcome {
    let matching = evidence.audit.findings.filter { auditNames.contains($0.rule) }
    if matching.isEmpty {
      return AccessibilityRuleOutcome(
        rule: rule, status: .pass, detail: "No problem was found for this rule.",
        findings: [], objects: objects)
    }
    let navigable = matching.map { finding in
      self.finding(
        rule: rule, severity: finding.severity, detail: finding.detail, objects: objects)
    }
    let status: AccessibilityRuleStatus
    if matching.contains(where: { $0.severity == .error }) {
      status = .fail
    } else if matching.contains(where: { $0.severity == .warning }) {
      status = .warning
    } else {
      status = .pass
    }
    return AccessibilityRuleOutcome(
      rule: rule, status: status,
      detail: matching.map(\.detail).joined(separator: " "),
      findings: navigable, objects: objects)
  }

  static func finding(
    rule: AccessibilityRuleDefinition, severity: PDFAccessibilityAudit.Finding.Severity,
    detail: String, objects: [AccessibilityObjectReference]
  ) -> AccessibilityNavigableFinding {
    AccessibilityNavigableFinding(
      id: rule.id + "/" + detail, ruleID: rule.id, ruleTitle: rule.title,
      severity: severity, detail: detail, mode: rule.mode, objects: objects,
      remediationTools: rule.remediationTools)
  }

  // MARK: Objects and metadata helpers

  static func catalogObject(_ evidence: Evidence) -> [AccessibilityObjectReference] {
    guard let catalogID = evidence.catalogID else { return [] }
    return [
      AccessibilityObjectReference(
        kind: .catalog, label: "Document catalog", objectID: catalogID)
    ]
  }

  static func metadataObjects(_ evidence: Evidence) -> [AccessibilityObjectReference] {
    var objects = catalogObject(evidence)
    if let id = evidence.xmpObjectID {
      objects.append(
        AccessibilityObjectReference(
          kind: .metadata, label: "XMP metadata", objectID: id))
    }
    return objects
  }

  static func pageIssueObjects(
    _ evidence: Evidence, kinds: Set<PDFStructureIssue.Kind>
  ) -> [AccessibilityObjectReference] {
    let issues = evidence.inventory.issues.filter { kinds.contains($0.kind) }
    if issues.isEmpty {
      return evidence.pageIDs.enumerated().map { index, pageID in
        AccessibilityObjectReference(
          kind: .page, label: "Page \(index + 1)", objectID: pageID, pageIndex: index)
      }
    }
    return issues.map { issue in
      AccessibilityObjectReference(
        kind: issue.objectID != nil ? .structureElement : .page,
        label: issue.pageIndex.map { "Page \($0 + 1)" } ?? "Structure issue",
        objectID: issue.objectID, pageIndex: issue.pageIndex,
        detail: issue.message)
    }
  }

  static func catalogDictionary(in graph: PDFGraph) -> [PDFName: PDFValue]? {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID]
    else { return nil }
    return catalog
  }

  static func infoDictionary(in graph: PDFGraph) -> [PDFName: PDFValue]? {
    if case .reference(let infoID)? = graph.trailer[PDFName("Info")],
      case .dictionary(let info)? = graph.objects[infoID]
    {
      return info
    }
    return nil
  }

  static func viewerDisplayDocTitle(
    catalog: [PDFName: PDFValue]?, graph: PDFGraph
  ) -> Bool {
    guard let catalog, let value = catalog[PDFName("ViewerPreferences")] else {
      return false
    }
    let preferences: [PDFName: PDFValue]?
    switch value {
    case .dictionary(let dictionary): preferences = dictionary
    case .reference(let id):
      if case .dictionary(let dictionary)? = graph.objects[id] {
        preferences = dictionary
      } else {
        preferences = nil
      }
    default:
      preferences = nil
    }
    return preferences?[PDFName("DisplayDocTitle")] == .boolean(true)
  }

  static func hasPDFUAIdentifier(_ xmp: String) -> Bool {
    guard xmp.contains("pdfuaid") else { return false }
    let normalized = xmp.replacingOccurrences(of: " ", with: "")
    return normalized.contains("pdfuaid:part>1<")
      || normalized.contains("pdfuaid:part=\"1\"")
      || normalized.contains("pdfuaid:part=1")
  }

  static func extractTitleFromXMP(_ xmp: String) -> String? {
    guard let start = xmp.range(of: "<dc:title>"),
      let end = xmp.range(of: "</dc:title>", range: start.upperBound..<xmp.endIndex)
    else { return nil }
    let inner = String(xmp[start.upperBound..<end.lowerBound])
    guard let liStart = inner.range(of: "<rdf:li"),
      let liOpenEnd = inner.range(of: ">", range: liStart.lowerBound..<inner.endIndex),
      let liClose = inner.range(
        of: "</rdf:li>", range: liOpenEnd.upperBound..<inner.endIndex)
    else { return nil }
    let title = String(inner[liOpenEnd.upperBound..<liClose.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? nil : title
  }
}
