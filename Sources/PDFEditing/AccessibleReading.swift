import Foundation
import PDFCore

/// A11Y-07: useful accessible reading, reflow and high-contrast access, plus a
/// verifier that checks whether document structure/tags survive text edits,
/// OCR, page assembly and exports.
///
/// The model is deliberately explicit about what it can and cannot prove:
/// automated structure checks never certify accessibility, VoiceOver itself is
/// not exercised by this module (the generated navigation script is manual
/// evidence), and an untagged document falls back to geometric order with an
/// explicit limitation rather than pretending to be semantic.
public enum AccessibleRole: String, Sendable, Equatable, CaseIterable {
  case heading
  case paragraph
  case listItem
  case table
  case tableRow
  case tableCell
  case figure
  case link
  case form
  case other

  /// Short spoken category used by the navigation script and UI.
  public var spokenName: String {
    switch self {
    case .heading: return "heading"
    case .paragraph: return "text"
    case .listItem: return "list item"
    case .table: return "table"
    case .tableRow: return "table row"
    case .tableCell: return "table cell"
    case .figure: return "figure"
    case .link: return "link"
    case .form: return "form field"
    case .other: return "content"
    }
  }
}

/// One item in accessible reading order.
public struct AccessibleReadingItem: Sendable, Equatable {
  public let role: AccessibleRole
  /// Readable text content (may be empty for a figure/link label).
  public let text: String
  /// Alt text, title, link target or field label when present.
  public let label: String?
  /// Heading level (1...6) for heading items.
  public let level: Int?
  public let pageIndex: Int?
  /// True when the item is generated searchable OCR text that is not in the
  /// document structure tree.
  public let isGeneratedOCR: Bool

  public init(
    role: AccessibleRole, text: String, label: String? = nil, level: Int? = nil,
    pageIndex: Int? = nil, isGeneratedOCR: Bool = false
  ) {
    self.role = role
    self.text = text
    self.label = label
    self.level = level
    self.pageIndex = pageIndex
    self.isGeneratedOCR = isGeneratedOCR
  }

  public var isEmpty: Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
  }

  /// VoiceOver-style announcement for the navigation script.
  public var spokenDescription: String {
    var parts: [String] = []
    if role == .heading {
      parts.append("heading level \(level ?? 1)")
    } else {
      parts.append(role.spokenName)
    }
    if let label, !label.isEmpty { parts.append(label) }
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !body.isEmpty { parts.append(body) }
    return parts.joined(separator: ", ")
  }
}

/// A11Y-07: the linear reading model plus reflow text and a VoiceOver-oriented
/// navigation script. It is derived from the structure tree when the document
/// is tagged, and from geometric page layout otherwise (declared limitation).
public struct AccessibleReadingModel: Sendable, Equatable {
  public let items: [AccessibleReadingItem]
  public let isTagged: Bool
  public let language: String?
  public let limitations: [String]
  public let structureIssueDescriptions: [String]

  public init(
    items: [AccessibleReadingItem], isTagged: Bool, language: String?,
    limitations: [String], structureIssueDescriptions: [String]
  ) {
    self.items = items
    self.isTagged = isTagged
    self.language = language
    self.limitations = limitations
    self.structureIssueDescriptions = structureIssueDescriptions
  }

  public var headings: [AccessibleReadingItem] { items.filter { $0.role == .heading } }
  public var links: [AccessibleReadingItem] { items.filter { $0.role == .link } }
  public var figures: [AccessibleReadingItem] { items.filter { $0.role == .figure } }
  public var tables: [AccessibleReadingItem] { items.filter { $0.role == .table } }

  public var plainText: String {
    items.filter { !$0.isEmpty }
      .map { item in
        switch item.role {
        case .heading: return String(repeating: "#", count: item.level ?? 1) + " " + item.text
        case .listItem: return "- " + item.text
        case .tableCell: return item.text
        case .figure: return "[Figure: " + (item.label ?? item.text) + "]"
        case .link: return item.text + (item.label.map { " (" + $0 + ")" } ?? "")
        case .form: return "[Form: " + (item.label ?? item.text) + "]"
        default: return item.text
        }
      }
      .joined(separator: "\n")
  }

  /// Reflow into a bounded-width accessible text stream. Structure markers are
  /// retained; table cells stay tab-separated inside their row.
  public func reflowedText(width: Int = 80) -> String {
    let width = max(32, min(width, 200))
    var lines: [String] = []
    for item in items where !item.isEmpty {
      let prefix: String
      switch item.role {
      case .heading: prefix = String(repeating: "#", count: item.level ?? 1) + " "
      case .listItem: prefix = "- "
      case .tableRow: prefix = "| "
      case .tableCell: prefix = ""
      case .figure: prefix = ""
      default: prefix = ""
      }
      let raw: String
      switch item.role {
      case .figure: raw = "[Figure: " + (item.label ?? item.text) + "]"
      case .link: raw = item.text + (item.label.map { " (" + $0 + ")" } ?? "")
      case .form: raw = "[Form: " + (item.label ?? item.text) + "]"
      default: raw = item.text
      }
      for line in reflow(raw, width: width - prefix.count) {
        lines.append(line.isEmpty ? line : prefix + line)
      }
    }
    return lines.joined(separator: "\n")
  }

  /// VoiceOver-oriented navigation evidence: ordered traversal steps plus rotor
  /// categories. Running them in VoiceOver is a human step; this script is the
  /// reproducible checklist, not a claim that VoiceOver was exercised here.
  public func voiceOverNavigationScript() -> [String] {
    var steps: [String] = []
    steps.append(
      "Document language: \(language ?? "not declared"); structure: \(isTagged ? "tagged" : "untagged (geometric order)").")
    steps.append("Read from top (\(items.count) items):")
    for (index, item) in items.enumerated() where !item.isEmpty {
      steps.append("  \(index + 1). \(item.spokenDescription)")
    }
    steps.append("Rotor > Headings (\(headings.count)):")
    for item in headings {
      steps.append("  H\(item.level ?? 1): \(item.text)")
    }
    steps.append("Rotor > Links (\(links.count)):")
    for item in links {
      steps.append("  \(item.text)\(item.label.map { " -> " + $0 } ?? "")")
    }
    steps.append("Rotor > Tables (\(tables.count)):")
    switch tables.count {
    case 0: steps.append("  no table elements")
    default:
      for item in tables { steps.append("  \(item.label ?? item.text)") }
    }
    steps.append("Figures with alternate text (\(figures.count)):")
    for item in figures {
      steps.append("  \(item.label ?? "(missing alt)")")
    }
    steps.append(
      "Limitations: \(limitations.isEmpty ? "none recorded" : limitations.joined(separator: " "))")
    return steps
  }

  public var summary: String {
    "\(items.count) reading items; \(headings.count) headings, \(links.count) links, "
      + "\(tables.count) tables, \(figures.count) figures; "
      + (isTagged ? "tagged order" : "geometric order (untagged)")
  }

  private func reflow(_ text: String, width: Int) -> [String] {
    let limit = max(16, width)
    var lines: [String] = []
    for paragraph in text.components(separatedBy: "\n") {
      var current = ""
      for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
        let token = String(word)
        if current.isEmpty {
          current = token
        } else if current.count + 1 + token.count <= limit {
          current += " " + token
        } else {
          lines.append(current)
          current = token
        }
      }
      lines.append(current)
    }
    return lines
  }
}

/// A11Y-07: build the accessible reading model from a graph.
public enum AccessibleReadingBuilder {
  public static func build(
    in graph: PDFGraph, pageIDs: [PDFObjectID], limits: PDFLimits = PDFLimits()
  ) throws -> AccessibleReadingModel {
    let inventory = try PDFStructureInspector.inspect(
      in: graph, pageIDs: pageIDs, limits: limits)
    let isTagged = inventory.rootObjectID != nil && inventory.hasMarkInfo
    var limitations: [String] = []
    var items: [AccessibleReadingItem] = []
    if isTagged, let rootID = inventory.rootObjectID {
      let roots = inventory.elements.filter {
        $0.parentObjectID == nil || $0.parentObjectID == rootID
      }
      let links = PDFLinkInventory.links(in: graph, pageIDs: pageIDs)
      var linkCursor = 0
      for element in roots {
        appendItems(
          element, pageIDs: pageIDs, graph: graph, links: links, linkCursor: &linkCursor,
          into: &items)
      }
      if items.isEmpty {
        limitations.append(
          "The structure tree contains no readable block elements; the geometric fallback was not used because the document is tagged.")
      }
    } else {
      limitations.append(
        "The document is not tagged (no MarkStructRoot/MarkInfo or no structure tree): reading order below is geometric (page order, top-to-bottom and left-to-right) and roles are unknown.")
      items = try geometricItems(in: graph, pageIDs: pageIDs)
    }
    let ocrPages = generatedOCRPages(in: graph, pageIDs: pageIDs)
    if !ocrPages.isEmpty {
      let descriptions = ocrPages.map { "page \($0 + 1)" }.joined(separator: ", ")
      limitations.append(
        "Generated searchable OCR text exists on \(descriptions) and is outside the document structure tree; screen readers that follow structure will not read it as tagged content.")
      // Surface the OCR layer in reading order so a human can review it, marked
      // explicitly as untagged generated text.
      for pageIndex in ocrPages {
        let pageText = try? geometricPageItems(in: graph, pageID: pageIDs[pageIndex], pageIndex: pageIndex)
        for var item in pageText ?? [] {
          item = AccessibleReadingItem(
            role: item.role, text: item.text, label: item.label, level: item.level,
            pageIndex: item.pageIndex, isGeneratedOCR: true)
          items.append(item)
        }
      }
    }
    if inventory.language?.isEmpty != false {
      limitations.append(
        "No catalog /Lang: assistive technology cannot select the correct voice automatically.")
    }
    let issues = inventory.issues.map { issue in
      "\(issue.kind.rawValue): \(issue.message)"
    }
    return AccessibleReadingModel(
      items: items, isTagged: isTagged, language: inventory.language,
      limitations: limitations, structureIssueDescriptions: issues)
  }

  // MARK: - Tagged traversal

  private static func appendItems(
    _ element: PDFStructureElement, pageIDs: [PDFObjectID], graph: PDFGraph,
    links: [PDFLinkTarget], linkCursor: inout Int, into items: inout [AccessibleReadingItem]
  ) {
    let role = element.role
    switch role {
    case "Document", "Sect", "Div", "Part", "Art", "NonStruct", "Private",
      "THead", "TBody", "TFoot":
      for child in element.children {
        if case .element(let nested) = child {
          appendItems(
            nested, pageIDs: pageIDs, graph: graph, links: links,
            linkCursor: &linkCursor, into: &items)
        }
      }
    case "L":
      for child in element.children {
        if case .element(let nested) = child {
          appendItems(
            nested, pageIDs: pageIDs, graph: graph, links: links,
            linkCursor: &linkCursor, into: &items)
        }
      }
    case "LI":
      let text = recursiveText(element, pageIDs: pageIDs, graph: graph)
      if !text.isEmpty {
        items.append(
          AccessibleReadingItem(
            role: .listItem, text: text, pageIndex: element.pageIndex))
      }
    case "H", "H1", "H2", "H3", "H4", "H5", "H6":
      let level: Int
      if role == "H" {
        level = 1
      } else {
        level = Int(role.dropFirst()) ?? 1
      }
      let text = recursiveText(element, pageIDs: pageIDs, graph: graph)
      items.append(
        AccessibleReadingItem(
          role: .heading, text: text, label: element.title, level: level,
          pageIndex: element.pageIndex))
    case "P", "Quote", "Note", "Code", "Caption", "Formula":
      let text = recursiveText(element, pageIDs: pageIDs, graph: graph)
      let label = element.actualText ?? element.title
      if !text.isEmpty || label != nil {
        items.append(
          AccessibleReadingItem(
            role: .paragraph, text: text, label: label, pageIndex: element.pageIndex))
      }
    case "Table":
      let label = element.title ?? element.alt ?? "table"
      items.append(
        AccessibleReadingItem(
          role: .table, text: "", label: label, pageIndex: element.pageIndex))
      for child in element.children {
        if case .element(let nested) = child {
          appendItems(
            nested, pageIDs: pageIDs, graph: graph, links: links,
            linkCursor: &linkCursor, into: &items)
        }
      }
    case "TR":
      for child in element.children {
        if case .element(let nested) = child {
          appendItems(
            nested, pageIDs: pageIDs, graph: graph, links: links,
            linkCursor: &linkCursor, into: &items)
        }
      }
    case "TH", "TD":
      let text = recursiveText(element, pageIDs: pageIDs, graph: graph)
      if !text.isEmpty {
        items.append(
          AccessibleReadingItem(
            role: .tableCell, text: text, label: element.title,
            pageIndex: element.pageIndex))
      }
    case "Figure":
      let alt = element.alt ?? element.actualText
      items.append(
        AccessibleReadingItem(
          role: .figure, text: "", label: alt, pageIndex: element.pageIndex))
    case "Link":
      let text = recursiveText(element, pageIDs: pageIDs, graph: graph)
      var target: String?
      if linkCursor < links.count {
        let candidate = links[linkCursor]
        linkCursor += 1
        if candidate.pageIndex == element.pageIndex {
          target = candidate.uri ?? candidate.destinationPageIndex.map { "page \($0 + 1)" }
        }
      }
      items.append(
        AccessibleReadingItem(
          role: .link, text: text.isEmpty ? "link" : text, label: target,
          pageIndex: element.pageIndex))
    case "Form":
      items.append(
        AccessibleReadingItem(
          role: .form, text: "", label: element.title ?? "form field",
          pageIndex: element.pageIndex))
    case "Lbl", "LBody", "Span", "Reference", "BibEntry", "Artifact", "Annot",
      "Ruby", "Warichu", "TOC", "TOCI", "Index":
      for child in element.children {
        if case .element(let nested) = child {
          appendItems(
            nested, pageIDs: pageIDs, graph: graph, links: links,
            linkCursor: &linkCursor, into: &items)
        }
      }
    default:
      for child in element.children {
        if case .element(let nested) = child {
          appendItems(
            nested, pageIDs: pageIDs, graph: graph, links: links,
            linkCursor: &linkCursor, into: &items)
        }
      }
    }
  }

  private static func recursiveText(
    _ element: PDFStructureElement, pageIDs: [PDFObjectID], graph: PDFGraph
  ) -> String {
    var parts: [String] = []
    let direct = (try? PDFStructureText.text(
      of: element, pageIDs: pageIDs, in: graph)) ?? ""
    if !direct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      parts.append(direct)
    }
    for child in element.children {
      if case .element(let nested) = child {
        let text = recursiveText(nested, pageIDs: pageIDs, graph: graph)
        if !text.isEmpty { parts.append(text) }
      }
    }
    return parts.joined(separator: " ")
  }

  // MARK: - Geometric fallback

  private static func geometricItems(in graph: PDFGraph, pageIDs: [PDFObjectID]) throws
    -> [AccessibleReadingItem]
  {
    var items: [AccessibleReadingItem] = []
    for (index, pageID) in pageIDs.enumerated() {
      items.append(
        contentsOf: try geometricPageItems(in: graph, pageID: pageID, pageIndex: index))
    }
    return items
  }

  private static func geometricPageItems(
    in graph: PDFGraph, pageID: PDFObjectID, pageIndex: Int
  ) throws -> [AccessibleReadingItem] {
    let layout = try PageTextLayout.build(pageID: pageID, in: graph)
    let text = PDFTextExport.text(of: layout.clusters, options: PDFTextExportOptions(pageSeparator: .none))
    return text.components(separatedBy: "\n").compactMap { line -> AccessibleReadingItem? in
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      return AccessibleReadingItem(role: .paragraph, text: trimmed, pageIndex: pageIndex)
    }
  }

  static func generatedOCRPages(in graph: PDFGraph, pageIDs: [PDFObjectID]) -> [Int] {
    var pages: [Int] = []
    for (index, pageID) in pageIDs.enumerated()
    where OCRLayer.hasGeneratedLayer(in: graph, pageID: pageID) {
      pages.append(index)
    }
    return pages
  }
}

/// A11Y-07: high-contrast access. Reports text runs whose contrast against the
/// page background is below the WCAG thresholds and offers a deterministic
/// display-only override. Contrast is computed from owned text runs, not from
/// rendering; only a white page background is assumed (declared limitation).
public struct HighContrastFinding: Sendable, Equatable {
  public enum Severity: String, Sendable, Equatable {
    case failure
    case warning
  }

  public let pageIndex: Int
  public let snippet: String
  public let fontSize: Double
  public let foreground: [Double]
  public let background: [Double]
  public let contrastRatio: Double
  public let threshold: Double
  public let severity: Severity

  public var description: String {
    "page \(pageIndex + 1) \(severity.rawValue): ratio \(String(format: "%.2f", contrastRatio))"
      + " (needs \(String(format: "%.1f", threshold)) at \(String(format: "%.1f", fontSize)) pt) "
      + "for \"\(snippet)\""
  }
}

public struct HighContrastReport: Sendable, Equatable {
  public let findings: [HighContrastFinding]
  public let checkedRunCount: Int
  public let limitations: [String]

  public var failureCount: Int { findings.filter { $0.severity == .failure }.count }
  public var warningCount: Int { findings.filter { $0.severity == .warning }.count }
  public var passesMachineChecks: Bool { failureCount == 0 }

  public func report() -> String {
    var lines = [
      "High-contrast audit — \(failureCount) failure\(failureCount == 1 ? "" : "s"), "
        + "\(warningCount) warning\(warningCount == 1 ? "" : "s"); \(checkedRunCount) text runs checked."
    ]
    for finding in findings { lines.append("  " + finding.description) }
    lines.append("Limitations: " + limitations.joined(separator: " "))
    return lines.joined(separator: "\n")
  }
}

public enum HighContrastAccess {
  public static let normalTextThreshold = 4.5
  public static let largeTextThreshold = 3.0
  public static let largeTextPointSize = 18.0

  public static func contrastRatio(foreground: [Double], background: [Double]) -> Double {
    let first = relativeLuminance(foreground)
    let second = relativeLuminance(background)
    let lighter = max(first, second)
    let darker = min(first, second)
    return (lighter + 0.05) / (darker + 0.05)
  }

  public static func relativeLuminance(_ color: [Double]) -> Double {
    guard color.count >= 3 else { return 0 }
    func channel(_ value: Double) -> Double {
      let clamped = min(1, max(0, value))
      return clamped <= 0.03928 ? clamped / 12.92 : pow((clamped + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(color[0]) + 0.7152 * channel(color[1])
      + 0.0722 * channel(color[2])
  }

  /// Deterministic display-only override suggestion for a page background.
  public static func suggestedOverride(background: [Double]) -> [Double] {
    relativeLuminance(background) > 0.4 ? [0, 0, 0] : [1, 1, 1]
  }

  public static func audit(in graph: PDFGraph, pageIDs: [PDFObjectID]) throws
    -> HighContrastReport
  {
    let background = [1.0, 1.0, 1.0]
    var findings: [HighContrastFinding] = []
    var checked = 0
    for (pageIndex, pageID) in pageIDs.enumerated() {
      let content = try PageContent.load(pageID: pageID, in: graph)
      let runs = try TextRunIndexer.runs(in: content, graph: graph)
      for run in runs {
        guard !run.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          continue
        }
        checked += 1
        let foreground = effectiveForeground(run.fillColor, alpha: run.fillAlpha, over: background)
        let size = run.pageSpaceFontSize
        let threshold = size >= largeTextPointSize ? largeTextThreshold : normalTextThreshold
        let ratio = contrastRatio(foreground: foreground, background: background)
        if ratio < threshold {
          findings.append(
            HighContrastFinding(
              pageIndex: pageIndex,
              snippet: String(run.text.prefix(60)),
              fontSize: size, foreground: foreground, background: background,
              contrastRatio: ratio, threshold: threshold,
              severity: ratio < threshold * 0.6 ? .failure : .warning))
        }
      }
    }
    return HighContrastReport(
      findings: findings, checkedRunCount: checked,
      limitations: [
        "Contrast is computed from owned text-run color state against an assumed white page background; page fills, images and blend modes behind text are not rendered.",
        "Meeting a contrast ratio is a machine check; color-only meaning and user preference (for example forced dark mode) remain human review items.",
      ])
  }

  static func effectiveForeground(_ color: [Double], alpha: Double, over background: [Double])
    -> [Double]
  {
    guard color.count >= 3, alpha.isFinite else { return [0, 0, 0] }
    let clampedAlpha = min(1, max(0, alpha))
    return (0..<3).map { index in
      min(1, max(0, color[index])) * clampedAlpha + background[index] * (1 - clampedAlpha)
    }
  }
}

/// A11Y-07: the operations whose tag preservation is verified.
public enum TagVerificationOperation: String, Sendable, Equatable, CaseIterable {
  case textEdit
  case ocr
  case pageAssembly
  case export

  public var displayName: String {
    switch self {
    case .textEdit: return "Text edit"
    case .ocr: return "OCR searchable-text layer"
    case .pageAssembly: return "Page assembly"
    case .export: return "Export"
    }
  }
}

/// A compact snapshot of the document's structure used to compare before/after
/// an operation. It is comparable and contains no graph references.
public struct TagSnapshot: Sendable, Equatable {
  public let isTagged: Bool
  public let hasMarkInfo: Bool
  public let language: String?
  public let elementCount: Int
  public let roleSequence: [String]
  public let roleCounts: [String: Int]
  /// Direct content pieces as role|page|mcid, in reading order.
  public let contentPieces: [String]
  /// Marked-content count per page index.
  public let pageMCIDCounts: [Int]
  public let generatedOCRPages: [Int]
  public let issueKinds: [String: Int]

  public var issueCount: Int { issueKinds.values.reduce(0, +) }

  public static func capture(in graph: PDFGraph, pageIDs: [PDFObjectID])
    throws -> TagSnapshot
  {
    let inventory = try PDFStructureInspector.inspect(in: graph, pageIDs: pageIDs)
    var roleSequence: [String] = []
    var contentPieces: [String] = []
    for element in inventory.elements {
      roleSequence.append(element.role)
      for child in element.children {
        if case .content(let pageIndex, let mcid) = child {
          contentPieces.append("\(element.role)|\(pageIndex ?? -1)|\(mcid)")
        }
      }
    }
    let roleCounts = Dictionary(grouping: roleSequence, by: { $0 }).mapValues(\.count)
    var issueKinds: [String: Int] = [:]
    for issue in inventory.issues { issueKinds[issue.kind.rawValue, default: 0] += 1 }
    return TagSnapshot(
      isTagged: inventory.rootObjectID != nil && inventory.hasMarkInfo,
      hasMarkInfo: inventory.hasMarkInfo,
      language: inventory.language,
      elementCount: inventory.elements.count,
      roleSequence: roleSequence,
      roleCounts: roleCounts,
      contentPieces: contentPieces,
      pageMCIDCounts: inventory.pageMCIDs.map(\.count),
      generatedOCRPages: AccessibleReadingBuilder.generatedOCRPages(
        in: graph, pageIDs: pageIDs),
      issueKinds: issueKinds)
  }
}

public enum TagPreservationStatus: String, Sendable, Equatable {
  case preserved
  case needsReview
  case untagged
  case degraded

  public var displayName: String {
    switch self {
    case .preserved: return "Preserved"
    case .needsReview: return "Preserved with review items"
    case .untagged: return "Not applicable (untagged source)"
    case .degraded: return "Degraded"
    }
  }
}

/// A11Y-07: the machine-checkable outcome of one operation on document
/// semantics, with attached limitations. It never claims accessibility
/// conformance.
public struct TagPreservationReport: Sendable, Equatable {
  public let operation: TagVerificationOperation
  public let status: TagPreservationStatus
  public let findings: [String]
  public let limitations: [String]

  public var isAcceptable: Bool { status != .degraded }

  public func report() -> String {
    var lines = [
      "\(operation.displayName) tag preservation: \(status.displayName)"
    ]
    for finding in findings { lines.append("  - " + finding) }
    for limitation in limitations { lines.append("  limitation: " + limitation) }
    return lines.joined(separator: "\n")
  }
}

public enum TagPreservationVerifier {
  public static let sharedLimitations = [
    "Automated structure comparison cannot prove semantic correctness or screen-reader outcomes; human review remains required.",
    "VoiceOver itself is not exercised by this verifier; use the generated navigation script as a manual checklist.",
  ]

  public static func verify(
    operation: TagVerificationOperation, before: TagSnapshot, after: TagSnapshot
  ) -> TagPreservationReport {
    var findings: [String] = []
    var limitations = sharedLimitations
    guard before.isTagged else {
      return TagPreservationReport(
        operation: operation, status: .untagged,
        findings: [
          "The source document has no usable structure tree; there is no tagged semantics to preserve. Any accessible reading relies on geometric fallback."
        ],
        limitations: limitations)
    }
    guard after.isTagged, after.hasMarkInfo else {
      return TagPreservationReport(
        operation: operation, status: .degraded,
        findings: ["The structure tree or MarkInfo is missing after \(operation.displayName.lowercased())."],
        limitations: limitations)
    }
    if after.issueCount > before.issueCount {
      findings.append(
        "Structure issue count increased from \(before.issueCount) to \(after.issueCount): \(after.issueKinds).")
      limitations.append(
        "New structure issues mean tagged semantics may be broken; inspect the affected elements before shipping.")
      return TagPreservationReport(
        operation: operation, status: .degraded, findings: findings,
        limitations: limitations)
    }
    switch operation {
    case .textEdit:
      if after.contentPieces != before.contentPieces {
        let removed = Set(before.contentPieces).subtracting(after.contentPieces)
        let added = Set(after.contentPieces).subtracting(before.contentPieces)
        findings.append(
          "Marked-content mapping changed (removed \(removed.count), added \(added.count)); edited text should keep its element/MCID mapping.")
        return TagPreservationReport(
          operation: operation, status: .degraded, findings: findings,
          limitations: limitations)
      }
      findings.append(
        "Every structure element and MCID mapping is unchanged; only text/ActualText content may have changed.")
      limitations.append(
        "Whether the replacement text still matches the heading/paragraph role is a human review item.")
      return TagPreservationReport(
        operation: operation, status: .preserved, findings: findings,
        limitations: limitations)
    case .ocr:
      if after.contentPieces != before.contentPieces {
        findings.append("OCR added or removed structure marked content; the searchable layer must not enter the structure tree.")
        return TagPreservationReport(
          operation: operation, status: .degraded, findings: findings,
          limitations: limitations)
      }
      let newOCR = after.generatedOCRPages.filter { !before.generatedOCRPages.contains($0) }
      if !newOCR.isEmpty {
        let pages = newOCR.map { "page \($0 + 1)" }.joined(separator: ", ")
        findings.append(
          "Generated searchable text was added on \(pages). The original structure is unchanged, but the OCR layer is outside the structure tree and its recognized text/quality needs human review.")
        limitations.append(
          "OCR text is not represented as tagged content in this profile; screen readers that follow tags will not read it.")
        return TagPreservationReport(
          operation: operation, status: .needsReview, findings: findings,
          limitations: limitations)
      }
      findings.append("No generated OCR layer was added; structure is unchanged.")
      return TagPreservationReport(
        operation: operation, status: .preserved, findings: findings,
        limitations: limitations)
    case .pageAssembly:
      let beforeCounts = before.roleCounts
      let afterCounts = after.roleCounts
      let beforePageCount = before.pageMCIDCounts.count
      let afterPageCount = after.pageMCIDCounts.count
      if beforePageCount != afterPageCount {
        findings.append(
          "Page count changed \(beforePageCount) -> \(afterPageCount); structure coverage for new pages is not synthesized. Verify that inserted/duplicated pages do not need tagged content.")
        limitations.append(
          "Page assembly does not author structure for new pages; this is a known limitation, not a pass.")
        return TagPreservationReport(
          operation: operation, status: .needsReview, findings: findings,
          limitations: limitations)
      }
      guard beforeCounts == afterCounts, before.roleSequence == after.roleSequence else {
        findings.append(
          "Element roles or reading order changed during page assembly (roles \(beforeCounts) -> \(afterCounts)).")
        return TagPreservationReport(
          operation: operation, status: .degraded, findings: findings,
          limitations: limitations)
      }
      if after.pageMCIDCounts != before.pageMCIDCounts {
        findings.append(
          "Per-page marked-content counts changed order/count during assembly; the tree's page children must still resolve to the intended page content.")
        limitations.append(
          "Verify logical reading order after page reordering: the tree order is preserved, but the pages' visual order changed.")
        return TagPreservationReport(
          operation: operation, status: .needsReview, findings: findings,
          limitations: limitations)
      }
      findings.append("Structure roles, reading order and per-page marked content are unchanged.")
      return TagPreservationReport(
        operation: operation, status: .preserved, findings: findings,
        limitations: limitations)
    case .export:
      findings.append(
        "The export operation did not mutate the source structure (this verifier compares derivative output separately).")
      limitations.append(
        "Derivative formats carry only the structure they choose to emit; use verifyExportOrder for the exported text order.")
      return TagPreservationReport(
        operation: operation, status: .preserved, findings: findings,
        limitations: limitations)
    }
  }

  /// Verify that a derivative's text follows the accessible reading order.
  public static func verifyExportOrder(
    derivativeText: String, model: AccessibleReadingModel
  ) -> TagPreservationReport {
    let normalized = normalize(derivativeText)
    let expected = model.items.filter { !$0.isEmpty }.map { normalize($0.text) }
      .filter { !$0.isEmpty }
    var cursor = normalized.startIndex
    var matched = 0
    var missing: [String] = []
    for item in expected {
      if let range = normalized.range(of: item, range: cursor..<normalized.endIndex) {
        matched += 1
        cursor = range.upperBound
      } else if missing.count < 5 {
        missing.append(String(item.prefix(40)))
      }
    }
    let ratio = expected.isEmpty ? 1 : Double(matched) / Double(expected.count)
    var findings: [String] = [
      "\(matched)/\(expected.count) accessible reading items appear in derivative order."
    ]
    if !missing.isEmpty {
      findings.append("Missing or out of order: " + missing.joined(separator: "; "))
    }
    let status: TagPreservationStatus
    if ratio >= 0.9 {
      status = .preserved
    } else if ratio >= 0.6 {
      status = .needsReview
    } else {
      status = .degraded
    }
    return TagPreservationReport(
      operation: .export, status: status, findings: findings,
      limitations: sharedLimitations + [
        "Text-order containment cannot prove that the derivative preserves headings, lists or tables as structure; those mappings need format-specific review."
      ])
  }

  private static func normalize(_ text: String) -> String {
    let collapsed = text.replacingOccurrences(
      of: "\\s+", with: " ", options: .regularExpression)
    return collapsed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
