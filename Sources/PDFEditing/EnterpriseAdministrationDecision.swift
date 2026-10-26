import Foundation
import PDFCore

// SCOPE-05: enterprise administration decision.
//
// Selected market: regulated document operations teams deploying the fixed macOS
// app on an MDM-managed fleet. This is explicitly a local desktop decision, not
// Acrobat Sign enterprise parity. The app supports a managed deployment policy
// contract and local enforcement report; cloud administration, SSO runtime and
// service-side retention are excluded and listed as out of scope.

public enum EnterpriseIdentityMode: String, Codable, Sendable, CaseIterable, Equatable {
  case managedDeviceOnly = "managed-device-only"
  case ssoContractOnly = "sso-contract-only"

  public var title: String {
    switch self {
    case .managedDeviceOnly: return "Managed device identity only"
    case .ssoContractOnly: return "SSO contract (integration deferred)"
    }
  }
}

public struct ManagedRetentionPolicy: Codable, Sendable, Equatable {
  public let localCacheDays: Int
  public let localAuditLogDays: Int

  public init(localCacheDays: Int, localAuditLogDays: Int) {
    self.localCacheDays = localCacheDays
    self.localAuditLogDays = localAuditLogDays
  }

  public func validate() throws {
    guard (0...90).contains(localCacheDays) else {
      throw PDFError(.malformed, "Managed cache retention must be between 0 and 90 days")
    }
    guard (1...3_650).contains(localAuditLogDays) else {
      throw PDFError(.malformed, "Managed audit-log retention must be between 1 and 3650 days")
    }
  }
}

public struct ManagedSupportPolicy: Codable, Sendable, Equatable {
  public let supportContact: String?
  public let diagnosticsExportEnabled: Bool

  public init(supportContact: String?, diagnosticsExportEnabled: Bool) {
    self.supportContact = supportContact
    self.diagnosticsExportEnabled = diagnosticsExportEnabled
  }

  public func validate() throws {
    if let supportContact {
      let trimmed = supportContact.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, trimmed.count <= 256 else {
        throw PDFError(.malformed, "Managed support contact must be a non-empty short string")
      }
    }
  }
}

public struct ManagedFeaturePolicy: Codable, Sendable, Equatable {
  public let disabledFeatureIDs: [String]
  public let allowedFeatureIDs: [String]?

  public init(disabledFeatureIDs: [String], allowedFeatureIDs: [String]? = nil) {
    self.disabledFeatureIDs = disabledFeatureIDs
    self.allowedFeatureIDs = allowedFeatureIDs
  }

  public func validate() throws {
    let disabled = Set(disabledFeatureIDs)
    guard disabled.count == disabledFeatureIDs.count else {
      throw PDFError(.malformed, "Disabled feature identifiers must be unique")
    }
    guard disabledFeatureIDs.allSatisfy({
      !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0.count <= 64
    }) else {
      throw PDFError(.malformed, "Disabled feature identifiers must be non-empty and short")
    }
    if let allowedFeatureIDs {
      let allowed = Set(allowedFeatureIDs)
      guard allowed.count == allowedFeatureIDs.count, !allowed.isEmpty else {
        throw PDFError(.malformed, "Allowed feature identifiers must be non-empty and unique")
      }
      guard allowed.isDisjoint(with: disabled) else {
        throw PDFError(.malformed, "A feature cannot be both allowed and disabled")
      }
    }
  }
}

/// SCOPE-05: the supported managed deployment contract. This is a local
/// property-list consumed by the app; it is not a cloud admin console and does
/// not implement identity providers or remote support.
public struct ManagedDeploymentPolicy: Codable, Sendable, Equatable {
  public static let schemaVersion = 1
  public static let topLevelKeys: Set<String> = [
    "schemaVersion", "organizationIdentifier", "deploymentIdentifier", "identityMode",
    "retention", "features", "support", "telemetryEnabled",
  ]

  public let schemaVersion: Int
  public let organizationIdentifier: String
  public let deploymentIdentifier: String
  public let identityMode: EnterpriseIdentityMode
  public let retention: ManagedRetentionPolicy
  public let features: ManagedFeaturePolicy
  public let support: ManagedSupportPolicy
  public let telemetryEnabled: Bool

  public init(
    schemaVersion: Int = ManagedDeploymentPolicy.schemaVersion,
    organizationIdentifier: String,
    deploymentIdentifier: String,
    identityMode: EnterpriseIdentityMode,
    retention: ManagedRetentionPolicy,
    features: ManagedFeaturePolicy,
    support: ManagedSupportPolicy,
    telemetryEnabled: Bool = false
  ) {
    self.schemaVersion = schemaVersion
    self.organizationIdentifier = organizationIdentifier
    self.deploymentIdentifier = deploymentIdentifier
    self.identityMode = identityMode
    self.retention = retention
    self.features = features
    self.support = support
    self.telemetryEnabled = telemetryEnabled
  }

  public func validate() throws {
    guard schemaVersion == Self.schemaVersion else {
      throw PDFError(.unsupported, "Unsupported managed deployment policy schema version")
    }
    try Self.validateIdentifier(
      organizationIdentifier, label: "organization identifier")
    try Self.validateIdentifier(
      deploymentIdentifier, label: "deployment identifier")
    try retention.validate()
    try features.validate()
    try support.validate()
    guard !telemetryEnabled else {
      throw PDFError(
        .unsupported,
        "The selected enterprise market policy does not enable telemetry; only local "
          + "diagnostics export is supported")
    }
  }

  static func validateIdentifier(_ value: String, label: String) throws {
    guard (3...128).contains(value.count) else {
      throw PDFError(.malformed, "The " + label + " must be 3...128 characters")
    }
    guard value.unicodeScalars.allSatisfy({
      CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "-"
    }) else {
      throw PDFError(.malformed, "The " + label + " may contain letters, digits, dot, dash or underscore")
    }
  }

  /// Decode only the supported local policy contract. Unknown top-level or
  /// nested keys are refused instead of silently ignored.
  public static func decode(propertyList data: Data) throws -> ManagedDeploymentPolicy {
    let object = try PropertyListSerialization.propertyList(
      from: data, options: [], format: nil)
    guard let dictionary = object as? [String: Any] else {
      throw PDFError(.malformed, "Managed deployment policy is not a dictionary property list")
    }
    let unknownTop = Set(dictionary.keys).subtracting(topLevelKeys)
    guard unknownTop.isEmpty else {
      throw PDFError(
        .unsupported,
        "Unsupported managed policy keys: " + unknownTop.sorted().joined(separator: ", "))
    }
    if let retention = dictionary["retention"] as? [String: Any] {
      let allowed: Set<String> = ["localCacheDays", "localAuditLogDays"]
      let unknown = Set(retention.keys).subtracting(allowed)
      guard unknown.isEmpty else {
        throw PDFError(
          .unsupported,
          "Unsupported retention keys: " + unknown.sorted().joined(separator: ", "))
      }
    }
    if let features = dictionary["features"] as? [String: Any] {
      let allowed: Set<String> = ["disabledFeatureIDs", "allowedFeatureIDs"]
      let unknown = Set(features.keys).subtracting(allowed)
      guard unknown.isEmpty else {
        throw PDFError(
          .unsupported,
          "Unsupported feature keys: " + unknown.sorted().joined(separator: ", "))
      }
    }
    if let support = dictionary["support"] as? [String: Any] {
      let allowed: Set<String> = ["supportContact", "diagnosticsExportEnabled"]
      let unknown = Set(support.keys).subtracting(allowed)
      guard unknown.isEmpty else {
        throw PDFError(
          .unsupported,
          "Unsupported support keys: " + unknown.sorted().joined(separator: ", "))
      }
    }
    let policy: ManagedDeploymentPolicy
    do {
      policy = try PropertyListDecoder().decode(ManagedDeploymentPolicy.self, from: data)
    } catch {
      throw PDFError(.malformed, "Managed deployment policy cannot be decoded: \(error)")
    }
    try policy.validate()
    return policy
  }

  public func encode() throws -> Data {
    try validate()
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .xml
    return try encoder.encode(self)
  }

  /// Local enforcement summary. Nothing here implies a server or cloud control.
  public var enforcementReport: String {
    var lines: [String] = [
      "Managed deployment policy (SCOPE-05 local contract)",
      "  Organization: \(organizationIdentifier)",
      "  Deployment: \(deploymentIdentifier)",
      "  Identity: \(identityMode.title) — no identity-provider runtime is implemented.",
      "  Local cache retention: \(retention.localCacheDays) day(s); audit log: "
        + "\(retention.localAuditLogDays) day(s).",
      "  Telemetry: disabled; diagnostics export: "
        + (support.diagnosticsExportEnabled ? "enabled" : "disabled") + ".",
    ]
    if !features.disabledFeatureIDs.isEmpty {
      lines.append(
        "  Disabled features: " + features.disabledFeatureIDs.sorted().joined(separator: ", "))
    }
    if let allowed = features.allowedFeatureIDs {
      lines.append("  Allowed features: " + allowed.sorted().joined(separator: ", "))
    }
    if let contact = support.supportContact {
      lines.append("  Support contact: " + contact)
    }
    lines.append(
      "  Boundary: local desktop policy only; there is no cloud admin console, remote "
        + "support service or cloud retention, and no Acrobat Sign enterprise admin parity.")
    return lines.joined(separator: "\n")
  }
}

public enum EnterpriseCapabilityStatus: String, Sendable, CaseIterable, Equatable {
  case supported
  case contractOnly
  case deferred
  case excluded

  public var title: String {
    switch self {
    case .supported: return "Supported locally"
    case .contractOnly: return "Contract only"
    case .deferred: return "Deferred"
    case .excluded: return "Out of scope"
    }
  }
}

public struct EnterpriseCapabilityDecision: Sendable, Equatable, Identifiable {
  public var id: String { identifier }
  public let identifier: String
  public let title: String
  public let status: EnterpriseCapabilityStatus
  public let detail: String
  public let prerequisites: [String]

  public init(
    identifier: String, title: String, status: EnterpriseCapabilityStatus,
    detail: String, prerequisites: [String] = []
  ) {
    self.identifier = identifier
    self.title = title
    self.status = status
    self.detail = detail
    self.prerequisites = prerequisites
  }
}

public struct EnterpriseAdministrationDecisionRecord: Sendable, Equatable {
  public let selectedMarket: String
  public let capabilities: [EnterpriseCapabilityDecision]
  public let excludedAcrobatSignOffers: [String]
  public let acceptanceCriteria: [String]
  public let boundaryNotes: [String]

  public init(
    selectedMarket: String, capabilities: [EnterpriseCapabilityDecision],
    excludedAcrobatSignOffers: [String], acceptanceCriteria: [String],
    boundaryNotes: [String]
  ) {
    self.selectedMarket = selectedMarket
    self.capabilities = capabilities
    self.excludedAcrobatSignOffers = excludedAcrobatSignOffers
    self.acceptanceCriteria = acceptanceCriteria
    self.boundaryNotes = boundaryNotes
  }

  public static let current = EnterpriseAdministrationDecisionRecord(
    selectedMarket:
      "One selected market: regulated document-operations teams running the fixed macOS "
      + "app on an MDM-managed fleet. Not a general enterprise service and not Acrobat Sign parity.",
    capabilities: [
      EnterpriseCapabilityDecision(
        identifier: "admin.managed-deployment",
        title: "Managed deployment and configuration",
        status: .supported,
        detail:
          "A signed, notarized macOS build is delivered by the existing release process; "
          + "administrators provide one validated property-list policy (ManagedDeploymentPolicy).",
        prerequisites: [
          "MDM distribution channel selected by the owner",
          "Signed/notarized release artifacts",
          "Policy schema reviewed for the selected market",
        ]),
      EnterpriseCapabilityDecision(
        identifier: "admin.identity",
        title: "Identity",
        status: .contractOnly,
        detail:
          "The policy records managed-device or SSO-contract identity mode. The app does not "
          + "implement an identity provider, SAML/OIDC runtime, cloud accounts or directory sync.",
        prerequisites: [
          "Identity-provider integration decision and owner review",
          "Managed-device trust model documented",
        ]),
      EnterpriseCapabilityDecision(
        identifier: "admin.support",
        title: "Support",
        status: .supported,
        detail:
          "Local diagnostics export and a policy-declared support contact; no remote support "
          + "channel, remote control or service telemetry.",
        prerequisites: ["Support contact and escalation process selected"]),
      EnterpriseCapabilityDecision(
        identifier: "admin.retention",
        title: "Retention controls",
        status: .supported,
        detail:
          "Local cache and local audit-log retention days are validated from policy. No cloud "
          + "retention or service-side audit trail is implemented.",
        prerequisites: ["Owner legal/records review of local retention bounds"]),
      EnterpriseCapabilityDecision(
        identifier: "admin.remote-service",
        title: "Remote administration service",
        status: .excluded,
        detail:
          "No hosted admin console, remote configuration service, tenant management or cloud "
          + "audit service is part of this macOS app.",
        prerequisites: []),
      EnterpriseCapabilityDecision(
        identifier: "admin.acrobat-sign",
        title: "Acrobat Sign enterprise administration",
        status: .excluded,
        detail:
          "Acrobat Sign enterprise agreement workflows, recipient management, admin console, "
          + "cloud audit trails and bulk sending are not claimed and not implemented.",
        prerequisites: []),
    ],
    excludedAcrobatSignOffers: [
      "Acrobat Sign enterprise agreement workflows and recipient management",
      "Acrobat Sign admin console, tenant policy and cloud licensing administration",
      "Acrobat Sign cloud audit trails and legal e-signature evidence service",
      "Bulk sending, web forms and reusable agreement templates",
      "Identity-provider administration and directory synchronization",
    ],
    acceptanceCriteria: [
      "A selected administrator can validate and apply the local managed deployment policy.",
      "Local retention, feature gates, diagnostics/support and telemetry-disabled rules are "
        + "enforced by the app contract.",
      "Pro desktop parity is never conflated with any Acrobat Sign enterprise offering.",
    ],
    boundaryNotes: [
      "Enterprise administration is a local macOS contract, not a service.",
      "No SSO/OIDC runtime, cloud console, remote support or cloud retention is implemented.",
      "Acrobat Sign enterprise features are explicit exclusions, not roadmap promises.",
    ])

  public func report() -> String {
    var lines: [String] = [
      "SCOPE-05 Enterprise administration decision",
      "Selected market: " + selectedMarket,
      "",
      "Capabilities:",
    ]
    for capability in capabilities {
      lines.append(
        "  [\(capability.status.title)] \(capability.identifier) — \(capability.title): "
          + capability.detail)
      for prerequisite in capability.prerequisites {
        lines.append("      prerequisite: " + prerequisite)
      }
    }
    lines.append("")
    lines.append("Excluded Acrobat Sign enterprise offers:")
    for offer in excludedAcrobatSignOffers { lines.append("  - " + offer) }
    lines.append("")
    lines.append("Acceptance criteria:")
    for criterion in acceptanceCriteria { lines.append("  - " + criterion) }
    lines.append("")
    lines.append("Boundary:")
    for note in boundaryNotes { lines.append("  - " + note) }
    return lines.joined(separator: "\n")
  }
}
