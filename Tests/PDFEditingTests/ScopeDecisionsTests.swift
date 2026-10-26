import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// SCOPE-05: selected enterprise market decision and the supported local
/// managed-deployment policy contract. No cloud console, SSO runtime or
/// Acrobat Sign enterprise parity is claimed.
@Suite("Enterprise administration decision (SCOPE-05)")
struct EnterpriseAdministrationDecisionTests {
  private func validPolicy() -> ManagedDeploymentPolicy {
    ManagedDeploymentPolicy(
      organizationIdentifier: "acme-legal.example",
      deploymentIdentifier: "fleet-2026-01",
      identityMode: .ssoContractOnly,
      retention: ManagedRetentionPolicy(localCacheDays: 7, localAuditLogDays: 400),
      features: ManagedFeaturePolicy(
        disabledFeatureIDs: ["ocr.cloud", "share.remote"],
        allowedFeatureIDs: ["pdf.edit", "ocr.local", "redact", "accessibility"]),
      support: ManagedSupportPolicy(
        supportContact: "support@acme.example", diagnosticsExportEnabled: true))
  }

  @Test func selectedMarketAndCapabilityMatrixAreExplicit() {
    let record = EnterpriseAdministrationDecisionRecord.current
    #expect(record.selectedMarket.contains("selected market"))
    #expect(!record.capabilities.isEmpty)
    #expect(Set(record.capabilities.map(\.identifier)).count == record.capabilities.count)
    #expect(record.capabilities.contains { $0.identifier == "admin.managed-deployment" && $0.status == .supported })
    #expect(record.capabilities.contains { $0.identifier == "admin.retention" && $0.status == .supported })
    #expect(record.capabilities.contains { $0.identifier == "admin.identity" && $0.status == .contractOnly })
    #expect(record.capabilities.contains { $0.identifier == "admin.acrobat-sign" && $0.status == .excluded })
    #expect(record.capabilities.contains { $0.identifier == "admin.remote-service" && $0.status == .excluded })
    // Excluded Acrobat Sign enterprise offerings are listed, never promised.
    #expect(
      record.excludedAcrobatSignOffers.contains {
        $0.contains("Acrobat Sign enterprise agreement workflows")
      })
    #expect(record.excludedAcrobatSignOffers.contains { $0.contains("admin console") })
    let report = record.report()
    #expect(report.contains("Selected market:"))
    #expect(report.contains("Out of scope"))
    #expect(report.contains("Pro desktop parity is never conflated"))
    #expect(report.contains("not a service"))
    for excluded in record.excludedAcrobatSignOffers {
      #expect(report.contains(excluded))
    }
  }

  @Test func managedPolicyRoundTripsThroughPropertyList() throws {
    let policy = validPolicy()
    try policy.validate()
    let data = try policy.encode()
    let decoded = try ManagedDeploymentPolicy.decode(propertyList: data)
    #expect(decoded == policy)
    #expect(decoded.retention.localCacheDays == 7)
    #expect(decoded.retention.localAuditLogDays == 400)
    #expect(decoded.features.disabledFeatureIDs == ["ocr.cloud", "share.remote"])
    #expect(decoded.support.supportContact == "support@acme.example")
    let report = decoded.enforcementReport
    #expect(report.contains("acme-legal.example"))
    #expect(report.contains("Local cache retention: 7 day(s)"))
    #expect(report.contains("Telemetry: disabled"))
    #expect(report.contains("no cloud admin console"))
    #expect(report.contains("no Acrobat Sign enterprise admin parity"))
  }

  @Test func invalidPoliciesAreRefusedWithReasons() throws {
    let base = validPolicy()
    let invalid = ManagedDeploymentPolicy(
      organizationIdentifier: "", deploymentIdentifier: base.deploymentIdentifier,
      identityMode: base.identityMode, retention: base.retention,
      features: base.features, support: base.support)
    #expect(throws: PDFError.self) { try invalid.validate() }
    let badDeployment = ManagedDeploymentPolicy(
      organizationIdentifier: base.organizationIdentifier,
      deploymentIdentifier: "bad deployment id!",
      identityMode: base.identityMode, retention: base.retention,
      features: base.features, support: base.support)
    #expect(throws: PDFError.self) { try badDeployment.validate() }
    let badContact = ManagedDeploymentPolicy(
      organizationIdentifier: base.organizationIdentifier,
      deploymentIdentifier: base.deploymentIdentifier,
      identityMode: base.identityMode, retention: base.retention,
      features: base.features,
      support: ManagedSupportPolicy(supportContact: "   ", diagnosticsExportEnabled: false))
    #expect(throws: PDFError.self) { try badContact.validate() }
  }

  @Test func policySchemaRejectsUnknownKeysAndBounds() throws {
    func plist(_ dictionary: [String: Any]) throws -> Data {
      try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }
    let base: [String: Any] = [
      "schemaVersion": 1,
      "organizationIdentifier": "acme-legal",
      "deploymentIdentifier": "fleet-1",
      "identityMode": "managed-device-only",
      "retention": ["localCacheDays": 7, "localAuditLogDays": 30],
      "features": ["disabledFeatureIDs": [String](), "allowedFeatureIDs": ["pdf.edit"]],
      "support": ["supportContact": "support@acme.example", "diagnosticsExportEnabled": true],
      "telemetryEnabled": false,
    ]
    var unknownTop = base
    unknownTop["cloudAdminURL"] = "https://example.invalid"
    #expect(throws: PDFError.self) {
      _ = try ManagedDeploymentPolicy.decode(propertyList: try plist(unknownTop))
    }
    var unknownRetention = base
    unknownRetention["retention"] = [
      "localCacheDays": 7, "localAuditLogDays": 30, "cloudDays": 99,
    ]
    #expect(throws: PDFError.self) {
      _ = try ManagedDeploymentPolicy.decode(propertyList: try plist(unknownRetention))
    }
    var badRetention = base
    badRetention["retention"] = ["localCacheDays": 500, "localAuditLogDays": 30]
    #expect(throws: PDFError.self) {
      _ = try ManagedDeploymentPolicy.decode(propertyList: try plist(badRetention))
    }
    var telemetry = base
    telemetry["telemetryEnabled"] = true
    #expect(throws: PDFError.self) {
      _ = try ManagedDeploymentPolicy.decode(propertyList: try plist(telemetry))
    }
    var badSchema = base
    badSchema["schemaVersion"] = 2
    #expect(throws: PDFError.self) {
      _ = try ManagedDeploymentPolicy.decode(propertyList: try plist(badSchema))
    }
    // Feature IDs must not be both allowed and disabled.
    #expect(throws: PDFError.self) {
      try ManagedFeaturePolicy(
        disabledFeatureIDs: ["ocr.local"], allowedFeatureIDs: ["ocr.local"]
      ).validate()
    }
    #expect(throws: PDFError.self) {
      try ManagedFeaturePolicy(disabledFeatureIDs: ["x", "x"]).validate()
    }
    // Out-of-range retention boundaries are refused.
    #expect(throws: PDFError.self) {
      try ManagedRetentionPolicy(localCacheDays: -1, localAuditLogDays: 30).validate()
    }
    #expect(throws: PDFError.self) {
      try ManagedRetentionPolicy(localCacheDays: 7, localAuditLogDays: 0).validate()
    }
    #expect(throws: PDFError.self) {
      try ManagedRetentionPolicy(localCacheDays: 7, localAuditLogDays: 3_651).validate()
    }
  }

  @Test func identityIsContractOnlyNotAnImplementedRuntime() {
    let record = EnterpriseAdministrationDecisionRecord.current
    let identity = record.capabilities.first { $0.identifier == "admin.identity" }
    #expect(identity?.status == .contractOnly)
    #expect(identity?.detail.contains("does not implement an identity provider") == true)
    #expect(record.boundaryNotes.contains { $0.contains("No SSO/OIDC runtime") })
    let policy = validPolicy()
    #expect(policy.identityMode == .ssoContractOnly)
    #expect(policy.enforcementReport.contains("no identity-provider runtime is implemented"))
  }
}

/// SCOPE-06: macOS stays the fixed target; each future platform requires its own
/// supported workflow matrix and never inherits macOS parity.
@Suite("Platform expansion decision (SCOPE-06)")
struct PlatformExpansionDecisionTests {
  @Test func decisionCoversEveryPlatformAndOnlyMacOSIsSupported() throws {
    let record = PlatformExpansionDecisionRecord.current
    try record.validate()
    #expect(record.fixedTarget == .macOS)
    #expect(record.matrices.count == PlatformExpansionTarget.allCases.count)
    #expect(
      record.matrices.filter { $0.status == .supported }.map(\.target) == [.macOS])
    let macOS = try #require(record.matrices.first { $0.target == .macOS })
    #expect(!macOS.supportedWorkflows.isEmpty)
    #expect(macOS.deferredWorkflows.isEmpty)
    #expect(macOS.prerequisites.isEmpty)
    for target in PlatformExpansionTarget.allCases where target != .macOS {
      let matrix = try #require(record.matrices.first { $0.target == target })
      #expect(matrix.status != .supported)
      #expect(matrix.supportedWorkflows.isEmpty)
      #expect(!matrix.deferredWorkflows.isEmpty)
      #expect(!matrix.requiredWork.isEmpty)
      #expect(!matrix.distributionRequirements.isEmpty)
      #expect(!matrix.prerequisites.isEmpty)
      #expect(matrix.parityClaimExcluded)
    }
  }

  @Test func parityStatementAndReportAreExplicit() {
    let report = PlatformExpansionDecisionRecord.current.report()
    #expect(report.contains("Fixed target: macOS"))
    #expect(report.contains("macOS completion is not cross-platform parity"))
    #expect(report.contains("Windows desktop — Deferred"))
    #expect(report.contains("iPhone/iPad — Deferred"))
    #expect(report.contains("Android — Deferred"))
    #expect(report.contains("Web browser — Deferred"))
    #expect(report.contains("Parity claim excluded: yes"))
    #expect(report.contains("prevents false parity claims"))
    #expect(
      PlatformExpansionDecisionRecord.current.parityStatement.contains(
        "not cross-platform parity"))
  }

  @Test func deferredPlatformsCarryRequiredWorkNotSupportClaims() {
    let record = PlatformExpansionDecisionRecord.current
    for matrix in record.matrices where matrix.target != .macOS {
      #expect(matrix.supportedWorkflows.isEmpty)
      #expect(matrix.requiredWork.contains { $0.contains("Separate") || $0.contains("separate") })
      #expect(
        matrix.distributionRequirements.contains {
          $0.lowercased().contains("store") || $0.lowercased().contains("installer")
            || $0.lowercased().contains("hosted")
        })
    }
  }

  @Test func invalidPlatformMatricesAreRefused() throws {
    let current = PlatformExpansionDecisionRecord.current
    // A deferred platform must not claim supported workflows.
    let badClaim = PlatformExpansionMatrix(
      target: .windows, status: .deferred,
      supportedWorkflows: ["Edit PDFs"], deferredWorkflows: ["Rest"],
      requiredWork: ["UI"], distributionRequirements: ["MSIX"],
      prerequisites: ["Budget"], parityClaimExcluded: true)
    #expect(throws: PDFError.self) { try badClaim.validate() }
    // A missing platform coverage is refused.
    var missing = current
    #expect(missing.matrices.count == 5)
    missing = PlatformExpansionDecisionRecord(
      fixedTarget: .macOS, decisionSummary: current.decisionSummary,
      matrices: Array(current.matrices.dropLast()),
      parityStatement: current.parityStatement, boundaryNotes: current.boundaryNotes)
    #expect(throws: PDFError.self) { try missing.validate() }
    // A second supported platform would be false parity.
    let secondSupported = PlatformExpansionMatrix(
      target: .windows, status: .supported,
      supportedWorkflows: ["Edit PDFs"], deferredWorkflows: [],
      requiredWork: [], distributionRequirements: [], prerequisites: [],
      parityClaimExcluded: true)
    let badTargets = PlatformExpansionDecisionRecord(
      fixedTarget: .macOS, decisionSummary: current.decisionSummary,
      matrices: [current.matrices[0], secondSupported]
        + current.matrices.filter { $0.target != .windows && $0.target != .macOS },
      parityStatement: current.parityStatement, boundaryNotes: current.boundaryNotes)
    #expect(throws: PDFError.self) { try badTargets.validate() }
    // A matrix without the parity exclusion is refused.
    let noParityExclusion = PlatformExpansionMatrix(
      target: .windows, status: .deferred, supportedWorkflows: [],
      deferredWorkflows: ["Rest"], requiredWork: ["UI"],
      distributionRequirements: ["MSIX"], prerequisites: ["Budget"],
      parityClaimExcluded: false)
    #expect(throws: PDFError.self) { try noParityExclusion.validate() }
    // The decision statement must include the explicit parity limitation.
    let noParityStatement = PlatformExpansionDecisionRecord(
      fixedTarget: .macOS, decisionSummary: current.decisionSummary,
      matrices: current.matrices, parityStatement: "Eventually supported.",
      boundaryNotes: current.boundaryNotes)
    #expect(throws: PDFError.self) { try noParityStatement.validate() }
  }
}
