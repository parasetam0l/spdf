import Foundation
import PDFCore

/// P37-015–P37-018: a PDF/UA audit that separates machine-checkable findings
/// from human-review requirements and never claims complete accessibility from
/// automated checks (or from successful rendering) alone.
public struct PDFAccessibilityAudit: Sendable, Equatable {
  public struct Finding: Sendable, Equatable {
    public enum Severity: String, Sendable, Equatable {
      case error
      case warning
      case info
    }

    public let rule: String
    public let severity: Severity
    public let detail: String

    public init(rule: String, severity: Severity, detail: String) {
      self.rule = rule
      self.severity = severity
      self.detail = detail
    }
  }

  public let findings: [Finding]
  /// Requirements only a human can evaluate — never reported as passed.
  public let humanReviewRequirements: [String]

  public init(findings: [Finding], humanReviewRequirements: [String]) {
    self.findings = findings
    self.humanReviewRequirements = humanReviewRequirements
  }

  public var errorCount: Int { findings.filter { $0.severity == .error }.count }
  public var warningCount: Int { findings.filter { $0.severity == .warning }.count }
  /// True when no machine-checkable error was found. This never means the
  /// document is accessible.
  public var passesMachineChecks: Bool { errorCount == 0 }

  public static let humanReviewChecklist = [
    "Alternate text quality and appropriateness (presence is machine-checked, meaning is not).",
    "Logical reading order and its match to the visual order.",
    "Color contrast and use of color alone to convey meaning.",
    "Link purpose understandable from the link text or context.",
    "Complex table structure and header associations beyond simple TH/TD presence.",
    "Scanned or OCR-derived text quality and language correctness.",
    "Whether interactive form behavior is understandable without vision.",
  ]

  /// P37-015/P37-016/P37-017: machine-checkable structure, language, alternate
  /// text, and form semantics over the parsed graph.
  public static func audit(
    _ graph: PDFGraph, pageIDs: [PDFObjectID], limits: PDFLimits = PDFLimits()
  ) -> PDFAccessibilityAudit {
    var findings: [Finding] = []
    let inventory = (try? PDFStructureInspector.inspect(in: graph, pageIDs: pageIDs, limits: limits))
      ?? PDFStructureInventory(
        rootObjectID: nil, roleMap: [:], classMap: [:], elements: [], parentTreeKeys: [],
        pageStructParents: [], pageMCIDs: [], issues: [], hasMarkInfo: false, language: nil,
        isTagged: false)

    // Structure presence and page tagging.
    if inventory.rootObjectID == nil {
      findings.append(
        Finding(
          rule: "Structure tree", severity: .error,
          detail: "No StructTreeRoot: the document is untagged and has no accessibility structure."))
    } else if !inventory.hasMarkInfo {
      findings.append(
        Finding(
          rule: "Marked content", severity: .error,
          detail: "A structure tree exists but MarkInfo/Marked is not true."))
    }
    let unmarked = inventory.issues.filter { $0.kind == .unmarkedPage }
    if !unmarked.isEmpty {
      findings.append(
        Finding(
          rule: "Page tagging", severity: .error,
          detail: "\(unmarked.count) page\(unmarked.count == 1 ? "" : "s") carry no marked content."))
    }
    let duplicateMCIDs = inventory.issues.filter { $0.kind == .duplicateMCID }
    if !duplicateMCIDs.isEmpty {
      findings.append(
        Finding(
          rule: "MCID uniqueness", severity: .error,
          detail: "\(duplicateMCIDs.count) duplicate MCID finding\(duplicateMCIDs.count == 1 ? "" : "s")."))
    }
    let missingParents = inventory.issues.filter { $0.kind == .missingParentTreeEntry }
    if !missingParents.isEmpty {
      findings.append(
        Finding(
          rule: "ParentTree", severity: .error,
          detail: "\(missingParents.count) page\(missingParents.count == 1 ? "" : "s") declare StructParents without a ParentTree entry."))
    }

    // Language.
    if inventory.language?.isEmpty != false {
      findings.append(
        Finding(
          rule: "Language", severity: .warning,
          detail: "No catalog /Lang: assistive technology cannot select the correct voice."))
    } else if let language = inventory.language {
      findings.append(
        Finding(rule: "Language", severity: .info, detail: "Catalog language: \(language)."))
    }

    // Alternate text on figures.
    let figures = inventory.elements.filter { $0.role == "Figure" }
    let figuresWithoutAlt = figures.filter { ($0.alt ?? "").isEmpty }
    if !figuresWithoutAlt.isEmpty {
      findings.append(
        Finding(
          rule: "Figure alternate text", severity: .error,
          detail: "\(figuresWithoutAlt.count) figure element\(figuresWithoutAlt.count == 1 ? "" : "s") without /Alt."))
    } else if !figures.isEmpty {
      findings.append(
        Finding(
          rule: "Figure alternate text", severity: .info,
          detail: "\(figures.count) figure element\(figures.count == 1 ? "" : "s") carry /Alt (quality is a human review item)."))
    }

    // Tables need headers when they exist.
    let tables = inventory.elements.filter { $0.role == "Table" }
    if !tables.isEmpty {
      let hasHeader = inventory.elements.contains { $0.role == "TH" }
      findings.append(
        Finding(
          rule: "Table headers", severity: hasHeader ? .info : .warning,
          detail: hasHeader
            ? "Table elements include TH headers."
            : "Table elements exist without TH headers; header associations need review."))
    }

    // Form semantics: field names and tooltips.
    let fields = (try? FormInventory.fields(in: graph, pageIDs: pageIDs)) ?? []
    let unnamed = fields.filter { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    if !unnamed.isEmpty {
      findings.append(
        Finding(
          rule: "Form field names", severity: .error,
          detail: "\(unnamed.count) form field\(unnamed.count == 1 ? "" : "s") without a name."))
    }
    if !fields.isEmpty {
      findings.append(
        Finding(
          rule: "Form semantics", severity: .info,
          detail: "\(fields.count) field\(fields.count == 1 ? "" : "s") inventoried; field descriptions (/TU) and required-state clarity remain human review items."))
    }

    // Rendering never proves accessibility.
    findings.append(
      Finding(
        rule: "Rendering", severity: .info,
        detail: "Successful rendering is not evidence of accessibility; only the machine checks above were evaluated."))

    return PDFAccessibilityAudit(
      findings: findings, humanReviewRequirements: humanReviewChecklist)
  }

  public func report() -> String {
    var lines = [
      "Accessibility audit (PDF/UA-oriented) — \(errorCount) error\(errorCount == 1 ? "" : "s"), \(warningCount) warning\(warningCount == 1 ? "" : "s")"
    ]
    lines.append(
      "Automated checks cannot prove accessibility: \(humanReviewRequirements.count) requirement\(humanReviewRequirements.count == 1 ? "" : "s") need human review.")
    for finding in findings {
      lines.append("  [\(finding.severity.rawValue)] \(finding.rule): \(finding.detail)")
    }
    lines.append("Human review required:")
    for requirement in humanReviewRequirements {
      lines.append("  - \(requirement)")
    }
    return lines.joined(separator: "\n")
  }
}
