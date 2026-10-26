import Foundation
import PDFCore

// SCOPE-06: platform expansion decision. The fixed target is macOS. Windows,
// mobile and browser applications require separate UI/platform, distribution,
// QA and release work beyond this app; macOS completion is never advertised as
// cross-platform parity. Each future platform must supply its own supported
// workflow matrix before any support claim is made.

public enum PlatformExpansionTarget: String, Sendable, CaseIterable, Equatable {
  case macOS
  case windows
  case iOS
  case android
  case webBrowser

  public var title: String {
    switch self {
    case .macOS: return "macOS"
    case .windows: return "Windows desktop"
    case .iOS: return "iPhone/iPad"
    case .android: return "Android"
    case .webBrowser: return "Web browser"
    }
  }

  public var isFixedTarget: Bool { self == .macOS }
}

public enum PlatformWorkflowStatus: String, Sendable, CaseIterable, Equatable {
  case supported
  case deferred
  case notPlanned

  public var title: String {
    switch self {
    case .supported: return "Supported"
    case .deferred: return "Deferred — separate work required"
    case .notPlanned: return "Not planned"
    }
  }
}

public struct PlatformExpansionMatrix: Sendable, Equatable, Identifiable {
  public var id: String { target.rawValue }
  public let target: PlatformExpansionTarget
  public let status: PlatformWorkflowStatus
  /// Only populated for a supported platform; a deferred platform cannot claim
  /// workflows in this decision record.
  public let supportedWorkflows: [String]
  public let deferredWorkflows: [String]
  public let requiredWork: [String]
  public let distributionRequirements: [String]
  public let prerequisites: [String]
  public let parityClaimExcluded: Bool

  public init(
    target: PlatformExpansionTarget, status: PlatformWorkflowStatus,
    supportedWorkflows: [String], deferredWorkflows: [String],
    requiredWork: [String], distributionRequirements: [String],
    prerequisites: [String], parityClaimExcluded: Bool
  ) {
    self.target = target
    self.status = status
    self.supportedWorkflows = supportedWorkflows
    self.deferredWorkflows = deferredWorkflows
    self.requiredWork = requiredWork
    self.distributionRequirements = distributionRequirements
    self.prerequisites = prerequisites
    self.parityClaimExcluded = parityClaimExcluded
  }

  public func validate() throws {
    if status == .supported {
      guard !supportedWorkflows.isEmpty else {
        throw PDFError(.malformed, "A supported platform needs a supported workflow matrix")
      }
    } else {
      guard supportedWorkflows.isEmpty else {
        throw PDFError(
          .malformed,
          "A deferred/not-planned platform must not claim supported workflows")
      }
      guard !requiredWork.isEmpty, !distributionRequirements.isEmpty,
        !prerequisites.isEmpty
      else {
        throw PDFError(
          .malformed,
          "A non-supported platform must name required work, distribution and prerequisites")
      }
    }
    guard parityClaimExcluded else {
      throw PDFError(
        .malformed,
        "Platform scope must explicitly exclude cross-platform parity claims")
    }
  }
}

public struct PlatformExpansionDecisionRecord: Sendable, Equatable {
  public let fixedTarget: PlatformExpansionTarget
  public let decisionSummary: String
  public let matrices: [PlatformExpansionMatrix]
  public let parityStatement: String
  public let boundaryNotes: [String]

  public init(
    fixedTarget: PlatformExpansionTarget, decisionSummary: String,
    matrices: [PlatformExpansionMatrix], parityStatement: String,
    boundaryNotes: [String]
  ) {
    self.fixedTarget = fixedTarget
    self.decisionSummary = decisionSummary
    self.matrices = matrices
    self.parityStatement = parityStatement
    self.boundaryNotes = boundaryNotes
  }

  private static let macOSWorkflows: [String] = [
    "Open, view, navigate and save PDFs",
    "Edit text, images, forms and annotations",
    "OCR, scan cleanup and redaction",
    "Accessibility checks and PDF/UA report",
    "Print preflight, colour-managed conversion and separation preview",
    "Measurements, layers and production marks",
    "Compare, review, comments and form workflows",
  ]

  public static let current = PlatformExpansionDecisionRecord(
    fixedTarget: .macOS,
    decisionSummary:
      "Keep macOS as the fixed, supported target. Do not start Windows, mobile or browser "
      + "applications in this roadmap; each requires separate UI/platform and distribution work.",
    matrices: [
      PlatformExpansionMatrix(
        target: .macOS, status: .supported,
        supportedWorkflows: macOSWorkflows, deferredWorkflows: [],
        requiredWork: ["Continue macOS release qualification and CI"],
        distributionRequirements: [
          "Signed, notarized macOS app distributed by the established release process"
        ],
        prerequisites: [],
        parityClaimExcluded: true),
      PlatformExpansionMatrix(
        target: .windows, status: .deferred,
        supportedWorkflows: [],
        deferredWorkflows: [
          "Document viewing/editing UI", "Native file association and printing",
          "Windows installer and code-signing pipeline", "Platform accessibility and input mapping",
        ],
        requiredWork: [
          "Separate WinUI/native UI implementation and platform services",
          "Independent renderer/print integration and plugin-free qualification",
          "Windows packaging, signing and update channel",
        ],
        distributionRequirements: [
          "Windows installer/MSIX, code signing and enterprise deployment story"
        ],
        prerequisites: [
          "Owner-approved platform market and staffing decision",
          "Independent Windows QA and release budget",
          "Separate supported-workflow matrix signed off before any claim",
        ],
        parityClaimExcluded: true),
      PlatformExpansionMatrix(
        target: .iOS, status: .deferred,
        supportedWorkflows: [],
        deferredWorkflows: [
          "Touch-first document UI and file-provider integration",
          "Mobile editing, annotation and form filling review",
          "App Store distribution and device QA",
        ],
        requiredWork: [
          "Separate SwiftUI/UIKit interaction model and mobile feature subset",
          "Independent device/OS-version QA and accessibility review",
        ],
        distributionRequirements: [
          "App Store review, signing/provisioning and privacy declarations"
        ],
        prerequisites: [
          "Owner-approved mobile scope and supported-workflow matrix",
          "Mobile QA, support and distribution plan",
        ],
        parityClaimExcluded: true),
      PlatformExpansionMatrix(
        target: .android, status: .deferred,
        supportedWorkflows: [],
        deferredWorkflows: [
          "Android document UI", "Play Store distribution", "Device/version QA",
        ],
        requiredWork: [
          "Separate Android UI/platform implementation",
          "Independent renderer, storage-provider and accessibility work",
        ],
        distributionRequirements: [
          "Play Store listing, signing and enterprise distribution path"
        ],
        prerequisites: [
          "Owner-approved Android market decision",
          "Android QA/support/distribution plan",
        ],
        parityClaimExcluded: true),
      PlatformExpansionMatrix(
        target: .webBrowser, status: .deferred,
        supportedWorkflows: [],
        deferredWorkflows: [
          "Browser editing UI", "Server or WASM document processing boundary",
          "Multi-tenant hosting, identity and data-retention design",
        ],
        requiredWork: [
          "Separate browser UI and explicit server/file-processing architecture",
          "Security, data-retention and identity design beyond the local macOS app",
        ],
        distributionRequirements: [
          "Hosted service or offline browser delivery, plus privacy/security review"
        ],
        prerequisites: [
          "Owner-approved service scope and hosting policy",
          "Independent security/privacy review and browser QA matrix",
        ],
        parityClaimExcluded: true),
    ],
    parityStatement:
      "macOS completion is not cross-platform parity. Windows, iOS, Android and browser are "
      + "deferred; each must have its own supported workflow matrix, distribution plan and "
      + "release qualification before any platform support is advertised.",
    boundaryNotes: [
      "The fixed target remains macOS; no Windows/mobile/browser application is started by this decision.",
      "Every deferred platform excludes parity claims and must define its own workflow matrix.",
      "This record does not budget, staff or schedule platform work; it prevents false parity claims.",
    ])

  public func validate() throws {
    let targets = matrices.map(\.target)
    guard Set(targets) == Set(PlatformExpansionTarget.allCases),
      targets.count == PlatformExpansionTarget.allCases.count
    else {
      throw PDFError(
        .malformed,
        "The platform decision must cover every platform target exactly once")
    }
    guard matrices.filter({ $0.status == .supported }).map(\.target) == [fixedTarget]
    else {
      throw PDFError(
        .malformed,
        "Only the fixed target may be supported in this decision record")
    }
    for matrix in matrices { try matrix.validate() }
    guard parityStatement.contains("not cross-platform parity") else {
      throw PDFError(
        .malformed,
        "The decision must state that macOS completion is not cross-platform parity")
    }
  }

  public func report() -> String {
    var lines: [String] = [
      "SCOPE-06 Platform expansion decision",
      "Fixed target: " + fixedTarget.title,
      "Decision: " + decisionSummary,
      "",
      "Parity statement: " + parityStatement,
      "",
      "Supported workflow matrices:",
    ]
    for matrix in matrices {
      lines.append("")
      lines.append("  " + matrix.target.title + " — " + matrix.status.title)
      if !matrix.supportedWorkflows.isEmpty {
        lines.append("    Supported workflows:")
        for workflow in matrix.supportedWorkflows {
          lines.append("      - " + workflow)
        }
      }
      if !matrix.deferredWorkflows.isEmpty {
        lines.append("    Deferred workflows:")
        for workflow in matrix.deferredWorkflows {
          lines.append("      - " + workflow)
        }
      }
      if !matrix.requiredWork.isEmpty {
        lines.append("    Required separate work:")
        for work in matrix.requiredWork { lines.append("      - " + work) }
      }
      if !matrix.distributionRequirements.isEmpty {
        lines.append("    Distribution requirements:")
        for requirement in matrix.distributionRequirements {
          lines.append("      - " + requirement)
        }
      }
      if !matrix.prerequisites.isEmpty {
        lines.append("    Prerequisites:")
        for prerequisite in matrix.prerequisites {
          lines.append("      - " + prerequisite)
        }
      }
      lines.append("    Parity claim excluded: yes")
    }
    lines.append("")
    lines.append("Boundary:")
    for note in boundaryNotes { lines.append("  - " + note) }
    return lines.joined(separator: "\n")
  }
}
