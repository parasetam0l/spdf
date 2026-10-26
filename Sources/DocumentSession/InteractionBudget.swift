import Foundation

/// UX-05: the declared interaction classes whose latency is budgeted. These are
/// measurement categories, not a product-performance claim.
public enum InteractionKind: String, Codable, Sendable, CaseIterable {
  case firstPageDisplay
  case scroll
  case zoom
  case textPreview
  case selection
  case search
  case cancellation

  /// True for the cancellation path, which has its own (1 s) starting target.
  public var isCancellation: Bool { self == .cancellation }

  public var title: String {
    switch self {
    case .firstPageDisplay: return "first-page display"
    case .scroll: return "scroll"
    case .zoom: return "zoom"
    case .textPreview: return "text preview"
    case .selection: return "selection"
    case .search: return "search"
    case .cancellation: return "cancellation"
    }
  }
}

/// UX-05: one declared p95 budget. Starting targets come from the roadmap:
/// sub-100 ms ordinary UI response and sub-1 s cancellation. They are proposed
/// targets for representative inputs, not claims about current performance.
public struct InteractionBudget: Codable, Sendable, Equatable {
  public static let ordinaryResponseP95Milliseconds = 100.0
  public static let searchP95Milliseconds = 250.0
  public static let cancellationP95Milliseconds = 1_000.0

  public let kind: InteractionKind
  public let p95Milliseconds: Double
  public let source: String

  public init(kind: InteractionKind, p95Milliseconds: Double, source: String) {
    self.kind = kind
    self.p95Milliseconds = p95Milliseconds
    self.source = source
  }

  /// The starting targets every evaluation uses unless a caller declares
  /// stricter ones. The source text keeps the "proposed target" framing.
  public static func startingTargets() -> [InteractionBudget] {
    let ordinary =
      "Proposed starting target from the roadmap: sub-100 ms ordinary UI response. "
      + "It is a target for measurement, not a claim about current performance."
    let cancellation =
      "Proposed starting target from the roadmap: sub-1 s cancellation. "
      + "It is a target for measurement, not a claim about current performance."
    let search =
      "Declared search target (p95) above the ordinary-UI starting target because search "
      + "covers indexing and result ranking; it is not a general responsiveness claim."
    return [
      InteractionBudget(
        kind: .firstPageDisplay, p95Milliseconds: ordinaryResponseP95Milliseconds,
        source: ordinary),
      InteractionBudget(
        kind: .scroll, p95Milliseconds: ordinaryResponseP95Milliseconds, source: ordinary),
      InteractionBudget(
        kind: .zoom, p95Milliseconds: ordinaryResponseP95Milliseconds, source: ordinary),
      InteractionBudget(
        kind: .textPreview, p95Milliseconds: ordinaryResponseP95Milliseconds,
        source: ordinary),
      InteractionBudget(
        kind: .selection, p95Milliseconds: ordinaryResponseP95Milliseconds,
        source: ordinary),
      InteractionBudget(
        kind: .search, p95Milliseconds: searchP95Milliseconds, source: search),
      InteractionBudget(
        kind: .cancellation, p95Milliseconds: cancellationP95Milliseconds,
        source: cancellation),
    ]
  }
}

/// UX-05: one measured interaction. The document class keeps results separate
/// (for example a small tagged page versus a large scanned page).
public struct InteractionSample: Codable, Sendable, Equatable {
  public let kind: InteractionKind
  public let milliseconds: Double
  public let documentClass: String
  public let note: String

  public init(
    kind: InteractionKind, milliseconds: Double, documentClass: String, note: String = ""
  ) {
    self.kind = kind
    self.milliseconds = milliseconds
    self.documentClass = documentClass
    self.note = note
  }
}

/// UX-05: a deterministic nearest-rank distribution (the same convention the
/// native workspace measurement uses), kept separate per category and class.
public struct InteractionDistribution: Codable, Sendable, Equatable {
  public let count: Int
  public let median: Double
  public let p95: Double
  public let p99: Double
  public let maximum: Double

  public init(_ values: [Double]) {
    let sorted = values.sorted()
    func percentile(_ fraction: Double) -> Double {
      guard !sorted.isEmpty else { return 0 }
      return sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))]
    }
    count = sorted.count
    median = percentile(0.5)
    p95 = percentile(0.95)
    p99 = percentile(0.99)
    maximum = sorted.last ?? 0
  }
}

public enum InteractionBudgetStatus: String, Codable, Sendable, CaseIterable {
  case met
  case missed
  case notMeasured
}

public struct InteractionBudgetResult: Codable, Sendable, Equatable {
  public let kind: InteractionKind
  public let documentClass: String
  public let budgetP95Milliseconds: Double
  public let distribution: InteractionDistribution?
  public let status: InteractionBudgetStatus
  public let note: String
}

/// UX-05: the named measurement context. A budget result only means something
/// for the hardware and input class it was measured on.
public struct InteractionMeasurementContext: Codable, Sendable, Equatable {
  public let hardware: String
  public let inputClass: String
  public let methodology: String

  public init(hardware: String, inputClass: String, methodology: String) {
    self.hardware = hardware
    self.inputClass = inputClass
    self.methodology = methodology
  }
}

/// UX-05: the report keeps met, missed and not-measured results separate, per
/// interaction and per document class. It never averages them into one score.
public struct InteractionBudgetReport: Codable, Sendable, Equatable {
  public static let framing =
    "Interaction budgets use p95 starting targets (sub-100 ms ordinary UI response and "
    + "sub-1 s cancellation) and are measured on the named hardware and input class only. "
    + "A met target is a result for that input, not a product-wide performance claim; "
    + "missed and not-measured targets are reported separately and are never averaged "
    + "into an overall score."

  public let context: InteractionMeasurementContext
  public let budgets: [InteractionBudget]
  public let results: [InteractionBudgetResult]
  public let issues: [String]

  public init(
    context: InteractionMeasurementContext, budgets: [InteractionBudget],
    results: [InteractionBudgetResult], issues: [String]
  ) {
    self.context = context
    self.budgets = budgets
    self.results = results
    self.issues = issues
  }

  public var metCount: Int { results.filter { $0.status == .met }.count }
  public var missedCount: Int { results.filter { $0.status == .missed }.count }
  public var notMeasuredCount: Int { results.filter { $0.status == .notMeasured }.count }
  public var isComplete: Bool { issues.isEmpty && notMeasuredCount == 0 && !results.isEmpty }
  /// True only when every declared category/class pair was measured and met.
  public var meetsDeclaredBudgets: Bool { isComplete && missedCount == 0 }

  public func results(kind: InteractionKind) -> [InteractionBudgetResult] {
    results.filter { $0.kind == kind }
  }

  public func markdown() -> String {
    var lines = [
      "# Interaction budget report", "",
      InteractionBudgetReport.framing, "",
      "Hardware: \(context.hardware)",
      "Input class: \(context.inputClass)",
      "Methodology: \(context.methodology)",
      "",
      "Met \(metCount), missed \(missedCount), not measured \(notMeasuredCount).",
      "",
      "| Interaction | Document class | p95 (ms) | Budget (ms) | Status |",
      "| --- | --- | --- | --- | --- |",
    ]
    for result in results {
      let p95 = result.distribution.map { String(format: "%.1f", $0.p95) } ?? "—"
      lines.append(
        "| \(result.kind.title) | \(result.documentClass) | \(p95) | "
          + "\(String(format: "%.0f", result.budgetP95Milliseconds)) | "
          + "\(result.status.rawValue) |")
    }
    lines.append("")
    lines.append("## Declared budgets")
    for budget in budgets {
      lines.append(
        "- \(budget.kind.title): p95 \(String(format: "%.0f", budget.p95Milliseconds)) ms. "
          + budget.source)
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

  /// UX-05: evaluate samples for every declared budget and every requested
  /// document class. A class with no samples becomes an explicit notMeasured
  /// row instead of being silently left out.
  public static func evaluate(
    samples: [InteractionSample],
    context: InteractionMeasurementContext,
    budgets: [InteractionBudget] = InteractionBudget.startingTargets(),
    documentClasses: [String] = []
  ) -> InteractionBudgetReport {
    var issues: [String] = []
    if context.hardware.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append("The measurement context has no named hardware")
    }
    if context.inputClass.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append("The measurement context has no named input class")
    }
    if context.methodology.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append("The measurement context has no methodology description")
    }
    var classes = Set(documentClasses)
    for sample in samples {
      classes.insert(sample.documentClass)
      if !sample.milliseconds.isFinite || sample.milliseconds < 0 {
        issues.append("Interaction sample has an invalid duration")
      }
    }
    if budgets.isEmpty { issues.append("No interaction budgets are declared") }
    let sortedClasses = classes.filter { !$0.isEmpty }.sorted()
    var results: [InteractionBudgetResult] = []
    for budget in budgets.sorted(by: { $0.kind.rawValue < $1.kind.rawValue }) {
      for documentClass in sortedClasses {
        let values = samples.filter {
          $0.kind == budget.kind && $0.documentClass == documentClass
        }.map(\.milliseconds)
        if values.isEmpty {
          results.append(
            InteractionBudgetResult(
              kind: budget.kind, documentClass: documentClass,
              budgetP95Milliseconds: budget.p95Milliseconds, distribution: nil,
              status: .notMeasured,
              note: "No samples for this interaction and document class."))
        } else {
          let distribution = InteractionDistribution(values)
          results.append(
            InteractionBudgetResult(
              kind: budget.kind, documentClass: documentClass,
              budgetP95Milliseconds: budget.p95Milliseconds, distribution: distribution,
              status: distribution.p95 <= budget.p95Milliseconds ? .met : .missed,
              note: ""))
        }
      }
    }
    return InteractionBudgetReport(
      context: context, budgets: budgets, results: results, issues: issues)
  }
}
