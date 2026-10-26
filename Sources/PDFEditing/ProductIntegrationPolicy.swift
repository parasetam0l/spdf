import Foundation
import PDFCore

// SCOPE-03/SCOPE-04 decision record enforced in code. This macOS desktop profile
// deliberately supports LOCAL agreement templates and local per-recipient output
// generation; hosted sending, web forms, remote signature requests and cloud
// storage are deferred to an explicitly selected hosted service. Calling a
// deferred channel is refused at the policy layer so no route can claim network
// collaboration by accident.

public enum IntegrationChannel: String, Sendable, Equatable, CaseIterable, Codable {
  case localFile, clipboard, print, localTemplateBatch
  case hostedSending, webFormHosting, remoteSignatureRequest, cloudStorageUpload, cloudStorageDownload
}

public enum IntegrationDecision: String, Sendable, Equatable, Codable {
  case supportedLocally
  case refusedUntilServiceSelected
  case requiresExplicitProductPolicy
  case deferredHostedService
}

public struct IntegrationPolicyDecision: Sendable, Equatable, Codable {
  public let channel: IntegrationChannel
  public let decision: IntegrationDecision
  public let rationale: String
  public init(channel: IntegrationChannel, decision: IntegrationDecision, rationale: String) {
    self.channel = channel; self.decision = decision; self.rationale = rationale
  }
  public var isUsable: Bool { decision == .supportedLocally }
}

public enum ProductIntegrationPolicy {
  public static let selectedHostedService: String? = nil

  public static func decide(_ channel: IntegrationChannel) -> IntegrationPolicyDecision {
    switch channel {
    case .localFile, .clipboard, .print:
      return .init(channel: channel, decision: .supportedLocally, rationale: "Local file and export channels are the shipped desktop workflow.")
    case .localTemplateBatch:
      return .init(channel: channel, decision: .supportedLocally, rationale: "Local reusable agreement templates and per-recipient output generation are supported without a network service.")
    case .hostedSending, .webFormHosting, .remoteSignatureRequest, .cloudStorageUpload, .cloudStorageDownload:
      return .init(channel: channel, decision: .refusedUntilServiceSelected, rationale: "Deferred to an explicitly selected hosted service; this desktop profile performs no upload, hosting, recipient routing or remote signing link.")
    }
  }

  public static func requireUsable(_ channel: IntegrationChannel) throws {
    let decision = decide(channel)
    guard decision.isUsable else {
      throw ProductIntegrationPolicyError.refused(decision)
    }
  }
}

public enum ProductIntegrationPolicyError: Error, Equatable {
  case refused(IntegrationPolicyDecision)
}

// SCOPE-03 local subset: reusable template metadata, revision and a per-recipient
// batch that tracks each recipient output separately (no data mixing).
public struct AgreementTemplate: Sendable, Equatable, Codable {
  public let templateID: String
  public let name: String
  public let revision: Int
  public let fields: [String]
  public init(templateID: String, name: String, revision: Int, fields: [String]) {
    self.templateID = templateID; self.name = name
    self.revision = revision; self.fields = fields
  }
  public var isValid: Bool {
    !templateID.trimmingCharacters(in: .whitespaces).isEmpty
      && !name.trimmingCharacters(in: .whitespaces).isEmpty
      && revision >= 1
      && Set(fields).count == fields.count
      && fields.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
  }
}

public struct AgreementRecipient: Sendable, Equatable, Codable {
  public let recipientID: String
  public let displayName: String
  public init(recipientID: String, displayName: String) {
    self.recipientID = recipientID; self.displayName = displayName
  }
}

public enum AgreementOutputStatus: String, Sendable, Equatable, Codable {
  case planned, completed, failed
}

public struct AgreementRecipientOutput: Sendable, Equatable, Codable {
  public let templateID: String
  public let templateRevision: Int
  public let recipientID: String
  public let outputName: String
  public var status: AgreementOutputStatus
  public var failureReason: String?
  public init(templateID: String, templateRevision: Int, recipientID: String, outputName: String, status: AgreementOutputStatus = .planned, failureReason: String? = nil) {
    self.templateID = templateID; self.templateRevision = templateRevision
    self.recipientID = recipientID; self.outputName = outputName
    self.status = status; self.failureReason = failureReason
  }
}

public struct AgreementBatch: Sendable, Equatable, Codable {
  public let template: AgreementTemplate
  public let outputs: [AgreementRecipientOutput]
  public init(template: AgreementTemplate, outputs: [AgreementRecipientOutput]) {
    self.template = template; self.outputs = outputs
  }
  public static func plan(
    template: AgreementTemplate, recipients: [AgreementRecipient]
  ) throws -> AgreementBatch {
    guard template.isValid else {
      throw PDFError(.malformed, "The agreement template metadata is invalid")
    }
    let ids = recipients.map(\.recipientID)
    guard !ids.isEmpty else { throw PDFError(.malformed, "A batch needs at least one recipient") }
    guard Set(ids).count == ids.count else {
      throw PDFError(.malformed, "Recipients must be unique; duplicate recipient data would mix outputs")
    }
    for recipient in recipients {
      guard !recipient.recipientID.trimmingCharacters(in: .whitespaces).isEmpty,
        !recipient.displayName.trimmingCharacters(in: .whitespaces).isEmpty
      else { throw PDFError(.malformed, "A recipient needs an ID and a display name") }
    }
    let outputs = recipients.map {
      AgreementRecipientOutput(
        templateID: template.templateID, templateRevision: template.revision,
        recipientID: $0.recipientID,
        outputName: "\(template.templateID)-r\(template.revision)-\($0.recipientID).pdf")
    }
    guard Set(outputs.map(\.outputName)).count == outputs.count else {
      throw PDFError(.malformed, "Recipient output names must be unique")
    }
    return AgreementBatch(template: template, outputs: outputs)
  }

  public var completed: [AgreementRecipientOutput] { outputs.filter { $0.status == .completed } }
  public var failed: [AgreementRecipientOutput] { outputs.filter { $0.status == .failed } }
  public var planned: [AgreementRecipientOutput] { outputs.filter { $0.status == .planned } }

  /// Rejects outputs produced from a different template revision so a batch
  /// cannot silently mix recipient data from older edits.
  public func audit() -> [String] {
    var issues: [String] = []
    for output in outputs where output.templateID != template.templateID
      || output.templateRevision != template.revision
    {
      issues.append("\(output.recipientID): output is from another template revision")
    }
    for output in failed where (output.failureReason ?? "").isEmpty {
      issues.append("\(output.recipientID): failed output has no recorded reason")
    }
    return issues
  }
}

