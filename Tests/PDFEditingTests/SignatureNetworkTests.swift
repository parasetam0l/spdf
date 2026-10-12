import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P30-024 evidence: timestamp/revocation networking is disabled by default
/// and never touches the network unless explicitly enabled.
@Suite("Signature networking")
struct SignatureNetworkTests {
  struct CountingClient: SignatureNetworkClient {
    let calls: LockedCounter
    let response: Data
    func fetch(url: URL, body: Data) throws -> Data {
      calls.increment()
      return response
    }
  }

  final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
  }

  @Test func networkingIsDisabledByDefault() throws {
    #expect(SignatureNetworkPolicy.disabled.isEnabled == false)
    #expect(SignatureNetworkPolicy.disabled.allowedEndpoints.isEmpty)
    let counter = LockedCounter()
    let client = CountingClient(calls: counter, response: Data("token".utf8))
    #expect(throws: PDFError.self) {
      _ = try SignatureNetworkService.fetchTimestamp(
        digest: Data([1, 2, 3]), endpoint: "https://ts.example.com",
        policy: .disabled, client: client)
    }
    #expect(throws: PDFError.self) {
      _ = try SignatureNetworkService.checkRevocation(
        certificateDER: Data([4, 5]), endpoint: "https://ocsp.example.com",
        policy: .disabled, client: client)
    }
    // No networking happened while disabled.
    #expect(counter.count == 0)
  }

  @Test func enabledEndpointsFetchOnlyThroughTheAllowList() throws {
    let counter = LockedCounter()
    let client = CountingClient(calls: counter, response: Data("token".utf8))
    let policy = SignatureNetworkPolicy(
      isEnabled: true, allowedEndpoints: ["https://ts.example.com"])
    let token = try SignatureNetworkService.fetchTimestamp(
      digest: Data([1, 2, 3]), endpoint: "https://ts.example.com",
      policy: policy, client: client)
    #expect(token == Data("token".utf8))
    #expect(counter.count == 1)
    // An endpoint outside the allow-list refuses without networking.
    #expect(throws: PDFError.self) {
      _ = try SignatureNetworkService.fetchTimestamp(
        digest: Data([1]), endpoint: "https://evil.example.com",
        policy: policy, client: client)
    }
    #expect(counter.count == 1)
    // Non-https endpoints refuse.
    #expect(throws: PDFError.self) {
      _ = try SignatureNetworkService.checkRevocation(
        certificateDER: Data([9]), endpoint: "http://ocsp.example.com",
        policy: SignatureNetworkPolicy(isEnabled: true, allowedEndpoints: ["http://ocsp.example.com"]),
        client: client)
    }
  }
}
