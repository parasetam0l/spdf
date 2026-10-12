import Foundation
import PDFCore

/// P30-024: optional timestamp/revocation networking, disabled by default.
/// Document processing stays local unless the owner explicitly enables an
/// endpoint *and* issues a request. When disabled, no network client is
/// touched — the calls refuse before any URL is constructed.
public struct SignatureNetworkPolicy: Sendable, Equatable {
  public var isEnabled: Bool
  public var allowedEndpoints: Set<String>

  public init(isEnabled: Bool = false, allowedEndpoints: Set<String> = []) {
    self.isEnabled = isEnabled
    self.allowedEndpoints = allowedEndpoints
  }

  public static var disabled: SignatureNetworkPolicy { SignatureNetworkPolicy() }

  func requireEnabled(endpoint: String) throws {
    guard isEnabled else {
      throw PDFError(.unsupported, "Timestamp/revocation networking is disabled; enable it explicitly first")
    }
    guard allowedEndpoints.contains(endpoint) else {
      throw PDFError(.unsupported, "Timestamp/revocation endpoint is not in the enabled allow-list")
    }
  }
}

/// The network seam, injected so tests prove no networking unless enabled.
public protocol SignatureNetworkClient: Sendable {
  func fetch(url: URL, body: Data) throws -> Data
}

public enum SignatureNetworkService {
  /// RFC 3161 timestamp request. Refuses before touching `client` unless the
  /// policy explicitly enables `endpoint`.
  public static func fetchTimestamp(
    digest: Data, endpoint: String, policy: SignatureNetworkPolicy, client: any SignatureNetworkClient
  ) throws -> Data {
    try policy.requireEnabled(endpoint: endpoint)
    guard let url = URL(string: endpoint), url.scheme == "https" else {
      throw PDFError(.malformed, "Timestamp endpoint must be an https URL")
    }
    return try client.fetch(url: url, body: digest)
  }

  /// OCSP/CRL revocation check. Refuses before touching `client` unless the
  /// policy explicitly enables `endpoint`. Offline validation (P30-028)
  /// remains the default and never implies a check happened.
  public static func checkRevocation(
    certificateDER: Data, endpoint: String, policy: SignatureNetworkPolicy,
    client: any SignatureNetworkClient
  ) throws -> Data {
    try policy.requireEnabled(endpoint: endpoint)
    guard let url = URL(string: endpoint), url.scheme == "https" else {
      throw PDFError(.malformed, "Revocation endpoint must be an https URL")
    }
    return try client.fetch(url: url, body: certificateDER)
  }
}
