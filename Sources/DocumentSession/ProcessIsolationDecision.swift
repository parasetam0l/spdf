import Foundation

/// UX-07: the heavy or untrusted boundaries evaluated for process isolation.
public enum IsolationBoundary: String, Codable, Sendable, CaseIterable {
  case parsingUntrustedFiles
  case decodingFilters
  case pageRendering
  case ocrRecognition
  case exportPackaging
  case networkSignatureAccess

  public var title: String {
    switch self {
    case .parsingUntrustedFiles: return "parsing untrusted PDFs"
    case .decodingFilters: return "decoding filters and streams"
    case .pageRendering: return "page rendering"
    case .ocrRecognition: return "OCR recognition"
    case .exportPackaging: return "export packaging"
    case .networkSignatureAccess: return "network signature access"
    }
  }
}

public enum IsolationDecision: String, Codable, Sendable, CaseIterable {
  /// Stays in the document process; containment comes from limits, per-job
  /// cancellation and document-local failure handling.
  case keepInProcess
  /// Only when evidence shows the failure needs a separate process.
  case isolateInWorkerProcess
  /// Recorded candidate: no implementation until the named evidence exists.
  case deferWithEvidence
}

public enum IsolationEvidenceStatus: String, Codable, Sendable, CaseIterable {
  case measured
  case notMeasured
}

/// UX-07: one decision-record entry. It records the current containment and the
/// evidence needed before any broad rewrite.
public struct IsolationDecisionEntry: Codable, Sendable, Equatable {
  public let boundary: IsolationBoundary
  public let decision: IsolationDecision
  public let rationale: String
  public let declaredResourceLimits: [String]
  public let cancellation: String
  public let failureContainment: String
  /// Evidence reference for the decision (measured evidence for isolate; the
  /// evidence still needed for defer).
  public let evidenceReference: String
  public let evidenceStatus: IsolationEvidenceStatus

  public init(
    boundary: IsolationBoundary, decision: IsolationDecision, rationale: String,
    declaredResourceLimits: [String] = [], cancellation: String = "",
    failureContainment: String = "", evidenceReference: String = "",
    evidenceStatus: IsolationEvidenceStatus = .notMeasured
  ) {
    self.boundary = boundary
    self.decision = decision
    self.rationale = rationale
    self.declaredResourceLimits = declaredResourceLimits
    self.cancellation = cancellation
    self.failureContainment = failureContainment
    self.evidenceReference = evidenceReference
    self.evidenceStatus = evidenceStatus
  }
}

/// UX-07: the isolation decision record. It is a decision record, not an
/// implementation claim: no XPC boundary is included unless an entry says
/// isolateInWorkerProcess with measured evidence.
public struct ProcessIsolationDecisionRecord: Codable, Sendable, Equatable {
  public static let currentState =
    "No XPC worker boundary is implemented or claimed by this record. Parsing, "
    + "decoding, rendering, OCR and export packaging currently run in the document "
    + "process under the existing PDFLimits bounds, per-job cancellation and "
    + "document-local failure handling. This record decides what stays in process, "
    + "what is a candidate for isolation and what evidence a broad rewrite would need."

  public static let containmentStatement =
    "Boundary containment today: a malformed file or a failed job fails that document/"
    + "job (parser errors are explicit and jobs are cancellable) without terminating "
    + "unrelated documents. This is the declared failure-containment claim; it is not a "
    + "claim that a hostile in-process decoder cannot crash the app, which is exactly what "
    + "the deferred isolation evidence is meant to establish before a rewrite."

  public static let noRewriteWithoutEvidence =
    "No process boundary is introduced without measured evidence that the current "
    + "in-process containment is insufficient; a broad orchestration rewrite is not "
    + "undertaken on speculation."

  public let entries: [IsolationDecisionEntry]
  public let issues: [String]

  public init(entries: [IsolationDecisionEntry]) {
    self.entries = entries
    self.issues = Self.validate(entries)
  }

  public var isolateDecisionCount: Int {
    entries.filter { $0.decision == .isolateInWorkerProcess }.count
  }
  public var deferredCount: Int {
    entries.filter { $0.decision == .deferWithEvidence }.count
  }
  public var keepInProcessCount: Int {
    entries.filter { $0.decision == .keepInProcess }.count
  }
  public var isComplete: Bool {
    issues.isEmpty
      && Set(entries.map(\.boundary)).count == IsolationBoundary.allCases.count
  }
  /// True only when an entry makes an isolation implementation claim.
  public var claimsImplementedIsolation: Bool { isolateDecisionCount > 0 }

  public func entry(for boundary: IsolationBoundary) -> IsolationDecisionEntry? {
    entries.first { $0.boundary == boundary }
  }

  public func markdown() -> String {
    var lines = [
      "# Process-isolation decision record", "",
      ProcessIsolationDecisionRecord.currentState, "",
      ProcessIsolationDecisionRecord.containmentStatement, "",
      ProcessIsolationDecisionRecord.noRewriteWithoutEvidence, "",
      "Decisions: keep in process \(keepInProcessCount), deferred with evidence "
        + "\(deferredCount), isolate \(isolateDecisionCount).",
      "",
      "| Boundary | Decision | Evidence | Containment / limits |",
      "| --- | --- | --- | --- |",
    ]
    for entry in entries {
      let evidence: String
      switch entry.decision {
      case .isolateInWorkerProcess:
        evidence = "\(entry.evidenceStatus.rawValue): \(entry.evidenceReference)"
      case .deferWithEvidence:
        evidence = "needed: \(entry.evidenceReference)"
      case .keepInProcess:
        evidence = entry.evidenceReference.isEmpty ? "current limits and cancellation" : entry.evidenceReference
      }
      lines.append(
        "| \(entry.boundary.title) | \(entry.decision.rawValue) | \(evidence) | "
          + "\(entry.failureContainment) |")
    }
    if !issues.isEmpty {
      lines.append("")
      lines.append("## Issues")
      for issue in issues { lines.append("- \(issue)") }
    }
    return lines.joined(separator: "\n")
  }

  public func jsonData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(self)
  }

  /// The current declared record: every boundary is covered, no boundary claims
  /// isolation, candidates carry the evidence they would need.
  public static func declared() -> ProcessIsolationDecisionRecord {
    let limits = ["PDFLimits bound object/stream/segment counts", "per-document memory cap"]
    let cancellation = "Per-job Task cancellation checked at bounded work intervals."
    return ProcessIsolationDecisionRecord(entries: [
      IsolationDecisionEntry(
        boundary: .parsingUntrustedFiles, decision: .deferWithEvidence,
        rationale: "Malformed input currently fails the parse of that document with an "
          + "explicit error and does not terminate unrelated documents.",
        declaredResourceLimits: limits, cancellation: cancellation,
        failureContainment: "Document-local parse failure; no shared decoder state.",
        evidenceReference: "Measured catastrophic malformed-input evidence (crash or "
          + "cross-document take-down) that current in-process containment cannot bound.",
        evidenceStatus: .notMeasured),
      IsolationDecisionEntry(
        boundary: .decodingFilters, decision: .deferWithEvidence,
        rationale: "Filter decoding is bounded by PDFLimits; a hostile codec crash would be "
          + "the evidence that justifies a worker boundary.",
        declaredResourceLimits: limits, cancellation: cancellation,
        failureContainment: "Decode failure rejects that stream with an explicit error.",
        evidenceReference: "Bounded malformed-stream evidence plus crash containment tests.",
        evidenceStatus: .notMeasured),
      IsolationDecisionEntry(
        boundary: .pageRendering, decision: .keepInProcess,
        rationale: "Rendering is display-driven and already cancellable per page; moving it "
          + "out of process would add latency to the measured interaction budgets.",
        declaredResourceLimits: ["per-view raster cache bounds", "page-size limits"],
        cancellation: "Page render tasks are cancelled when the view changes or the document "
          + "closes.",
        failureContainment: "A failed render leaves the page unavailable without closing the "
          + "document.",
        evidenceReference: "Interaction budget measurements (UX-05 report)"),
      IsolationDecisionEntry(
        boundary: .ocrRecognition, decision: .keepInProcess,
        rationale: "OCR runs as a cancellable job with explicit fallback reporting; the "
          + "existing job cancellation bounds the interaction cost.",
        declaredResourceLimits: ["one recognition job at a time", "page-count bounds"],
        cancellation: "OCRJob checks cancellation between pages.",
        failureContainment: "Recognition failure reports an error and leaves the document "
          + "unchanged.",
        evidenceReference: "OCR job/cancellation suites"),
      IsolationDecisionEntry(
        boundary: .exportPackaging, decision: .keepInProcess,
        rationale: "Export is a user-initiated derivative job with explicit cancellation and "
          + "verified output; it does not decode untrusted bytes.",
        declaredResourceLimits: ["package size limits", "image/zip limits"],
        cancellation: "Export jobs are cancellable before the final atomic write.",
        failureContainment: "A failed export does not touch the source document.",
        evidenceReference: "Export cancellation and verification suites"),
      IsolationDecisionEntry(
        boundary: .networkSignatureAccess, decision: .keepInProcess,
        rationale: "Network signature access is a bounded request whose failure is reported; "
          + "it does not parse untrusted document structure.",
        declaredResourceLimits: ["request timeout", "bounded response size"],
        cancellation: "Signing tasks are cancellable and report revocation/network failures.",
        failureContainment: "Signature failure leaves the document unsigned and unchanged.",
        evidenceReference: "Signing network policy suites"),
    ])
  }

  static func validate(_ entries: [IsolationDecisionEntry]) -> [String] {
    var issues: [String] = []
    var seen = Set<IsolationBoundary>()
    for entry in entries {
      if !seen.insert(entry.boundary).inserted {
        issues.append("Duplicate isolation boundary: \(entry.boundary.rawValue)")
      }
      if entry.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append("Isolation boundary \(entry.boundary.rawValue) has no rationale")
      }
      if entry.failureContainment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append(
          "Isolation boundary \(entry.boundary.rawValue) has no containment statement")
      }
      switch entry.decision {
      case .isolateInWorkerProcess:
        if entry.evidenceReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || entry.evidenceStatus != .measured
        {
          issues.append(
            "Isolation boundary \(entry.boundary.rawValue) claims a worker process without "
              + "measured evidence")
        }
        if entry.declaredResourceLimits.isEmpty
          || entry.cancellation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          issues.append(
            "Isolation boundary \(entry.boundary.rawValue) has no declared limits/cancellation")
        }
      case .deferWithEvidence:
        if entry.evidenceReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          issues.append(
            "Deferred boundary \(entry.boundary.rawValue) does not name the evidence it needs")
        }
      case .keepInProcess:
        if entry.declaredResourceLimits.isEmpty
          || entry.cancellation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          issues.append(
            "In-process boundary \(entry.boundary.rawValue) has no declared limits/cancellation")
        }
      }
    }
    for boundary in IsolationBoundary.allCases where !seen.contains(boundary) {
      issues.append("Isolation boundary missing from the record: \(boundary.rawValue)")
    }
    return issues
  }
}
