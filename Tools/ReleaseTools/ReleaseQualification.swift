import Foundation

/// REL-01: workflow-level release coverage. Each row is one operation on one
/// document class producing one output claim, with its own status. The four
/// statuses are reported separately; no checklist count or parser success is
/// ever presented as an Acrobat-replacement percentage.
public enum ReleaseCoverageStatus: String, Codable, Sendable, CaseIterable {
  case passed
  case failed
  case refused
  case notTested
}

public struct ReleaseCoverageCounts: Codable, Sendable, Equatable {
  public let passed: Int
  public let failed: Int
  public let refused: Int
  public let notTested: Int

  public init(passed: Int, failed: Int, refused: Int, notTested: Int) {
    self.passed = passed
    self.failed = failed
    self.refused = refused
    self.notTested = notTested
  }

  public var total: Int { passed + failed + refused + notTested }
  public var hasFailures: Bool { failed > 0 }
}

public struct ReleaseCoverageEntry: Codable, Sendable, Equatable {
  public let id: String
  public let operation: String
  public let documentClass: String
  public let outputClaim: String
  public let status: ReleaseCoverageStatus
  /// Where the result is recorded (test suite, log, manual report).
  public let evidence: String
  /// Required explanation for failed/refused rows; optional otherwise.
  public let note: String

  public init(
    id: String, operation: String, documentClass: String, outputClaim: String,
    status: ReleaseCoverageStatus, evidence: String, note: String = ""
  ) {
    self.id = id
    self.operation = operation
    self.documentClass = documentClass
    self.outputClaim = outputClaim
    self.status = status
    self.evidence = evidence
    self.note = note
  }
}

public enum ReleaseCoverageDimension: String, Codable, Sendable, CaseIterable {
  case operation
  case documentClass
  case outputClaim
}

public struct ReleaseCoverageReport: Codable, Sendable, Equatable {
  /// The honest framing every report carries.
  public static let framingStatement =
    "Release coverage is reported as separate passed, failed, refused and not-tested "
    + "rows for each operation, document class and output claim. It is not an "
    + "Acrobat-replacement percentage; neither checkbox counts nor parser success is "
    + "presented as one."

  public static let verificationStatement =
    "Every passed row names its evidence. Failed and refused rows explain why. "
    + "Not-tested rows state what remains open instead of being folded into a score."

  public let entries: [ReleaseCoverageEntry]
  public let issues: [String]

  public init(entries: [ReleaseCoverageEntry]) {
    self.entries = entries
    self.issues = Self.validate(entries)
  }

  public var counts: ReleaseCoverageCounts {
    var passed = 0
    var failed = 0
    var refused = 0
    var notTested = 0
    for entry in entries {
      switch entry.status {
      case .passed: passed += 1
      case .failed: failed += 1
      case .refused: refused += 1
      case .notTested: notTested += 1
      }
    }
    return ReleaseCoverageCounts(
      passed: passed, failed: failed, refused: refused, notTested: notTested)
  }

  public var isConsistent: Bool { issues.isEmpty }
  public var hasFailures: Bool { counts.hasFailures }

  public func entries(status: ReleaseCoverageStatus) -> [ReleaseCoverageEntry] {
    entries.filter { $0.status == status }
  }

  /// Grouped counts for one declared dimension (operation, document class or
  /// output claim). Groups are sorted for deterministic reports.
  public func grouped(_ dimension: ReleaseCoverageDimension)
    -> [(key: String, counts: ReleaseCoverageCounts)]
  {
    var buckets: [String: [ReleaseCoverageEntry]] = [:]
    for entry in entries {
      let key: String
      switch dimension {
      case .operation: key = entry.operation
      case .documentClass: key = entry.documentClass
      case .outputClaim: key = entry.outputClaim
      }
      buckets[key, default: []].append(entry)
    }
    return buckets.keys.sorted().map { key in
      let rows = buckets[key] ?? []
      var passed = 0
      var failed = 0
      var refused = 0
      var notTested = 0
      for row in rows {
        switch row.status {
        case .passed: passed += 1
        case .failed: failed += 1
        case .refused: refused += 1
        case .notTested: notTested += 1
        }
      }
      return (
        key,
        ReleaseCoverageCounts(
          passed: passed, failed: failed, refused: refused, notTested: notTested))
    }
  }

  public func markdown() -> String {
    var lines = [
      "# Release workflow coverage", "",
      ReleaseCoverageReport.framingStatement, "",
      ReleaseCoverageReport.verificationStatement, "",
      "Rows: \(entries.count); passed \(counts.passed), failed \(counts.failed), "
        + "refused \(counts.refused), not tested \(counts.notTested).",
      "",
      "## Rows",
      "",
      "| ID | Operation | Document class | Output claim | Status | Evidence | Note |",
      "| --- | --- | --- | --- | --- | --- | --- |",
    ]
    for entry in entries {
      lines.append(
        "| \(entry.id) | \(entry.operation) | \(entry.documentClass) | "
          + "\(entry.outputClaim) | \(entry.status.rawValue) | \(entry.evidence) | "
          + "\(entry.note) |")
    }
    for dimension in ReleaseCoverageDimension.allCases {
      lines.append("")
      lines.append("## By \(dimension.rawValue)")
      lines.append("")
      lines.append("| \(dimension.rawValue) | Passed | Failed | Refused | Not tested |")
      lines.append("| --- | --- | --- | --- | --- |")
      for group in grouped(dimension) {
        lines.append(
          "| \(group.key) | \(group.counts.passed) | \(group.counts.failed) | "
            + "\(group.counts.refused) | \(group.counts.notTested) |")
      }
    }
    if !issues.isEmpty {
      lines.append("")
      lines.append("## Consistency issues")
      for issue in issues { lines.append("- \(issue)") }
    }
    return lines.joined(separator: "\n")
  }

  public func jsonData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(self)
  }

  static func validate(_ entries: [ReleaseCoverageEntry]) -> [String] {
    var issues: [String] = []
    var seen = Set<String>()
    for entry in entries {
      if !seen.insert(entry.id).inserted {
        issues.append("Duplicate coverage row id: \(entry.id)")
      }
      for (label, value) in [
        ("operation", entry.operation), ("documentClass", entry.documentClass),
        ("outputClaim", entry.outputClaim),
      ] where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append("Coverage row \(entry.id) has an empty \(label)")
      }
      if entry.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append("A coverage row has an empty id")
      }
      switch entry.status {
      case .passed, .refused:
        if entry.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          issues.append(
            "Coverage row \(entry.id) is \(entry.status.rawValue) without evidence")
        }
        if entry.status == .refused,
          entry.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          issues.append("Refused coverage row \(entry.id) has no explanation")
        }
      case .failed:
        if entry.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          issues.append("Failed coverage row \(entry.id) has no explanation")
        }
      case .notTested:
        break
      }
    }
    return issues
  }
}

/// REL-02: topics that still need integration evidence. Only closure by
/// evidence or by an explicit supported-profile exclusion counts; an open
/// question blocks candidate qualification.
public enum ReleaseIntegrationTopic: String, Codable, Sendable, CaseIterable {
  case actualOCRExecution
  case independentCryptographicValidation
  case interactionChangedByNewCode
  case other
}

public enum ReleaseIntegrationClosure: String, Codable, Sendable, CaseIterable {
  case evidence
  case excluded
  case open
}

public struct ReleaseIntegrationQuestion: Codable, Sendable, Equatable {
  public let id: String
  public let topic: ReleaseIntegrationTopic
  public let question: String
  public let closure: ReleaseIntegrationClosure
  /// Required when closure is evidence.
  public let evidenceReference: String
  /// Required when closure is excluded: the supported profile that is out.
  public let exclusionProfile: String
  /// Required when closure is excluded: why the profile is explicitly out.
  public let exclusionReason: String
  public let note: String

  public init(
    id: String, topic: ReleaseIntegrationTopic, question: String,
    closure: ReleaseIntegrationClosure, evidenceReference: String = "",
    exclusionProfile: String = "", exclusionReason: String = "", note: String = ""
  ) {
    self.id = id
    self.topic = topic
    self.question = question
    self.closure = closure
    self.evidenceReference = evidenceReference
    self.exclusionProfile = exclusionProfile
    self.exclusionReason = exclusionReason
    self.note = note
  }
}

public struct ReleaseIntegrationRegister: Codable, Sendable, Equatable {
  /// REL-02: default replay policy. Previously passed form, review and page
  /// workflows and the owner-accepted P48-009 result are not replayed by this
  /// report; only integration questions are tracked here.
  public static let replayPolicy =
    "Previously passed form, review and page workflows, and the owner-accepted "
    + "P48-009 result, are not replayed by default. This register only tracks the "
    + "remaining integration questions (actual OCR execution, independent "
    + "cryptographic validation, and interactions changed by new code); each is "
    + "closed by evidence or by an explicit supported-profile exclusion."

  public let questions: [ReleaseIntegrationQuestion]
  public let issues: [String]

  public init(questions: [ReleaseIntegrationQuestion]) {
    self.questions = questions
    self.issues = Self.validate(questions)
  }

  public var openQuestions: [ReleaseIntegrationQuestion] {
    questions.filter { $0.closure == .open }
  }
  public var evidenceQuestions: [ReleaseIntegrationQuestion] {
    questions.filter { $0.closure == .evidence }
  }
  public var excludedQuestions: [ReleaseIntegrationQuestion] {
    questions.filter { $0.closure == .excluded }
  }
  public var openCount: Int { openQuestions.count }
  public var isClosed: Bool { openQuestions.isEmpty }
  public var isConsistent: Bool { issues.isEmpty }
  public var blocksReleaseQualification: Bool { !isClosed || !isConsistent }

  public func questions(for topic: ReleaseIntegrationTopic) -> [ReleaseIntegrationQuestion] {
    questions.filter { $0.topic == topic }
  }

  public func markdown() -> String {
    var lines = [
      "# Remaining integration evidence", "",
      ReleaseIntegrationRegister.replayPolicy, "",
      "Questions: \(questions.count); evidence \(evidenceQuestions.count), "
        + "excluded \(excludedQuestions.count), open \(openCount).",
      "",
      "| ID | Topic | Question | Closure | Evidence / exclusion |",
      "| --- | --- | --- | --- | --- |",
    ]
    for question in questions {
      let resolution: String
      switch question.closure {
      case .evidence: resolution = question.evidenceReference
      case .excluded:
        resolution = "Excluded profile: \(question.exclusionProfile) — "
          + question.exclusionReason
      case .open: resolution = "Open"
      }
      lines.append(
        "| \(question.id) | \(question.topic.rawValue) | \(question.question) | "
          + "\(question.closure.rawValue) | \(resolution) |")
    }
    if !issues.isEmpty {
      lines.append("")
      lines.append("## Consistency issues")
      for issue in issues { lines.append("- \(issue)") }
    }
    return lines.joined(separator: "\n")
  }

  public func jsonData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(self)
  }

  static func validate(_ questions: [ReleaseIntegrationQuestion]) -> [String] {
    var issues: [String] = []
    var seen = Set<String>()
    for question in questions {
      if !seen.insert(question.id).inserted {
        issues.append("Duplicate integration question id: \(question.id)")
      }
      if question.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append("An integration question has an empty id")
      }
      if question.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append("Integration question \(question.id) has no question text")
      }
      switch question.closure {
      case .evidence:
        if question.evidenceReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          issues.append(
            "Integration question \(question.id) is closed by evidence but has no reference")
        }
      case .excluded:
        if question.exclusionProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || question.exclusionReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          issues.append(
            "Integration question \(question.id) is excluded without a profile and reason")
        }
      case .open:
        break
      }
    }
    return issues
  }
}

/// REL-01 + REL-02: the release qualification start declaration. It binds the
/// workflow coverage and the remaining-integration closure to one source SHA
/// and app version, and explicitly lists what it does NOT claim.
public struct ReleaseQualificationDeclaration: Codable, Sendable, Equatable {
  public enum Verdict: String, Codable, Sendable {
    case readyForCandidateBuild
    case blocked
  }

  public static let claimStatement =
    "This declaration starts release qualification only: it binds workflow-level "
    + "coverage and closed integration evidence to one source SHA and app version. It "
    + "does not claim Acrobat replacement or a percentage score, and it does not claim "
    + "a signed/notarized candidate, an installed candidate, a live update, or owner "
    + "workflow acceptance."

  public static let notClaimed: [String] = [
    "Signed/notarized candidate package production and verification (REL-03)",
    "Installation and representative changed-workflow verification on a candidate build (REL-03)",
    "Live update and relaunch through the published feed (REL-04)",
    "Owner workflow acceptance and public help accuracy (REL-05)",
  ]

  public let sourceSHA: String
  public let appVersion: String
  public let coverage: ReleaseCoverageReport
  public let integration: ReleaseIntegrationRegister
  public let verdict: Verdict
  public let blockers: [String]

  public init(
    sourceSHA: String, appVersion: String, coverage: ReleaseCoverageReport,
    integration: ReleaseIntegrationRegister
  ) throws {
    let cleanSHA = sourceSHA.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard cleanSHA.count == 40 || cleanSHA.count == 64,
      cleanSHA.allSatisfy({ $0.isHexDigit })
    else {
      throw ReleaseToolsError.invalid(
        "The release qualification needs a full 40- or 64-character hexadecimal source SHA")
    }
    let cleanVersion = appVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanVersion.isEmpty, cleanVersion.count <= 128,
      cleanVersion.rangeOfCharacter(from: CharacterSet.newlines) == nil
    else {
      throw ReleaseToolsError.invalid("The release qualification needs an app version")
    }
    self.sourceSHA = cleanSHA
    self.appVersion = cleanVersion
    self.coverage = coverage
    self.integration = integration
    var blockers: [String] = []
    if !coverage.isConsistent {
      blockers.append("Coverage report has consistency issues: \(coverage.issues.count)")
    }
    let failed = coverage.entries(status: .failed)
    if !failed.isEmpty {
      blockers.append(
        "\(failed.count) failed coverage row(s): "
          + failed.map(\.id).sorted().joined(separator: ", "))
    }
    if !integration.isConsistent {
      blockers.append("Integration register has consistency issues: \(integration.issues.count)")
    }
    if !integration.isClosed {
      blockers.append(
        "\(integration.openCount) open integration question(s): "
          + integration.openQuestions.map(\.id).sorted().joined(separator: ", "))
    }
    self.blockers = blockers
    self.verdict = blockers.isEmpty ? .readyForCandidateBuild : .blocked
  }

  public var isReadyForCandidateBuild: Bool { verdict == .readyForCandidateBuild }

  public func markdown() -> String {
    var lines = [
      "# Release qualification start", "",
      ReleaseQualificationDeclaration.claimStatement, "",
      "Source SHA: \(sourceSHA)",
      "App version: \(appVersion)",
      "Verdict: \(verdict.rawValue)",
      "",
      "## Not claimed by this declaration",
      "",
    ]
    for item in ReleaseQualificationDeclaration.notClaimed {
      lines.append("- \(item)")
    }
    if !blockers.isEmpty {
      lines.append("")
      lines.append("## Blockers")
      for blocker in blockers { lines.append("- \(blocker)") }
    }
    lines.append("")
    lines.append(coverage.markdown())
    lines.append("")
    lines.append(integration.markdown())
    return lines.joined(separator: "\n")
  }

  public func jsonData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(self)
  }
}
