import Foundation
import PDFCore

/// P38-014: operation budgets for suspicious documents. The budgets are a
/// superset of `PDFLimits` with wall-clock expectations so hostile inputs fail
/// within bounded resources rather than merely eventually.
public struct HardeningBudget: Sendable {
  /// Byte/file limits handed to the core parser and filters.
  public var limits: PDFLimits
  /// Wall-clock budget for parsing one document.
  public var parseMilliseconds: Int
  /// Wall-clock budget for one analysis pass (inventory/inspection) per page.
  public var analysisMillisecondsPerPage: Int
  /// Memory growth budget for one operation (bytes).
  public var memoryBytes: Int
  /// Maximum declared objects before a document is treated as suspicious.
  public var suspiciousObjects: Int
  /// Maximum declared pages before a document is treated as suspicious.
  public var suspiciousPages: Int
  /// P06-023: how many leading bytes explicit repair mode scans for object
  /// headers. Bounds triage work on hostile inputs; files whose headers
  /// start later are reported, not silently half-rebuilt.
  public var scanBytes: Int

  public init(
    limits: PDFLimits = PDFLimits(), parseMilliseconds: Int = 5_000,
    analysisMillisecondsPerPage: Int = 250, memoryBytes: Int = 512 * 1_024 * 1_024,
    suspiciousObjects: Int = 50_000, suspiciousPages: Int = 10_000,
    scanBytes: Int = 64 * 1_024 * 1_024
  ) {
    self.limits = limits
    self.parseMilliseconds = parseMilliseconds
    self.analysisMillisecondsPerPage = analysisMillisecondsPerPage
    self.memoryBytes = memoryBytes
    self.suspiciousObjects = suspiciousObjects
    self.suspiciousPages = suspiciousPages
    self.scanBytes = max(0, scanBytes)
  }

  /// The conservative default for untrusted documents.
  public static let untrusted = HardeningBudget()

  /// A stricter budget for clearly hostile inputs (fuzzing, repair triage).
  public static let hostile = HardeningBudget(
    limits: PDFLimits(fileBytes: 8 * 1_024 * 1_024, objects: 20_000, streamBytes: 8 * 1_024 * 1_024,
      decodedBytes: 16 * 1_024 * 1_024),
    parseMilliseconds: 2_000, analysisMillisecondsPerPage: 100,
    memoryBytes: 128 * 1_024 * 1_024, suspiciousObjects: 10_000, suspiciousPages: 2_000)
}

/// P38-018: sanity checks for huge sparse indices and unreasonable declared
/// counts. Findings are evidence for repair/refusal decisions — the graph is
/// never modified here.
public struct PDFSanityReport: Sendable, Equatable {
  public struct Finding: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
      /// The xref /Size is far larger than the objects actually present.
      case sparseObjectIndex
      /// An object number exceeds the configured object limit.
      case objectNumberOutOfRange
      /// The page tree declares more pages than the budget allows.
      case unreasonablePageCount
      /// The page tree /Count disagrees with the pages actually reachable.
      case pageCountMismatch
      /// The document declares more objects than the budget allows.
      case unreasonableObjectCount
    }

    public let kind: Kind
    public let detail: String

    public init(kind: Kind, detail: String) {
      self.kind = kind
      self.detail = detail
    }
  }

  public let findings: [Finding]

  public init(findings: [Finding]) {
    self.findings = findings
  }

  public var isSuspicious: Bool { !findings.isEmpty }

  public static func check(
    _ graph: PDFGraph, pageIDs: [PDFObjectID], budget: HardeningBudget = .untrusted
  ) -> PDFSanityReport {
    var findings: [Finding] = []
    let objectCount = graph.objects.count
    if objectCount > budget.suspiciousObjects {
      findings.append(
        Finding(
          kind: .unreasonableObjectCount,
          detail: "\(objectCount) objects exceeds the suspicious-object budget \(budget.suspiciousObjects)."))
    }
    let highest = graph.objects.keys.map(\.number).max() ?? 0
    if highest > budget.limits.objects {
      findings.append(
        Finding(
          kind: .objectNumberOutOfRange,
          detail: "Object number \(highest) exceeds the configured object limit \(budget.limits.objects)."))
    } else if highest > max(objectCount * 8, 4_096) {
      findings.append(
        Finding(
          kind: .sparseObjectIndex,
          detail: "Highest object number \(highest) is far above the \(objectCount) objects present."))
    }
    if pageIDs.count > budget.suspiciousPages {
      findings.append(
        Finding(
          kind: .unreasonablePageCount,
          detail: "\(pageIDs.count) pages exceeds the suspicious-page budget \(budget.suspiciousPages)."))
    }
    // The page tree's declared /Count must match the reachable pages.
    if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID],
      case .reference(let pagesID)? = catalog[PDFName("Pages")],
      case .dictionary(let pages)? = graph.objects[pagesID],
      case .integer(let declared)? = pages[PDFName("Count")],
      declared != Int64(pageIDs.count)
    {
      findings.append(
        Finding(
          kind: .pageCountMismatch,
          detail: "The page tree declares \(declared) pages but \(pageIDs.count) are reachable."))
    }
    return PDFSanityReport(findings: findings)
  }

  public func report() -> String {
    if findings.isEmpty { return "Sanity check: no suspicious indices or counts." }
    var lines = ["Sanity check: \(findings.count) finding\(findings.count == 1 ? "" : "s")"]
    for finding in findings {
      lines.append("  [\(finding.kind.rawValue)] \(finding.detail)")
    }
    return lines.joined(separator: "\n")
  }
}
