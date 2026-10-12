import CryptoKit
import Foundation
import Security

/// P28-022: credential retention is an explicit preference. Nothing is stored
/// unless the user asks for it; when asked, the credential goes to the login
/// keychain under a per-document account derived from the standardized path.
/// The store never logs or inspects passwords beyond round-tripping them.
public enum KeychainCredentialStore {
  static let service = "com.parasetam0l.spdf"

  static func account(forDocumentAt url: URL) -> String {
    let path = url.standardizedFileURL.path
    let digest = SHA256.hash(data: Data(path.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  /// Stores or replaces the credential. Returns false when the environment
  /// denies keychain access (the caller keeps the explicit preference unset).
  @discardableResult
  public static func save(password: String, forDocumentAt url: URL) -> Bool {
    guard let data = password.data(using: .utf8) else { return false }
    let account = account(forDocumentAt: url)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
    var attributes = query
    attributes[kSecValueData as String] = data
    attributes[kSecAttrLabel as String] = "sPDF Editor: \(url.lastPathComponent)"
    return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
  }

  public static func password(forDocumentAt url: URL) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account(forDocumentAt: url),
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  @discardableResult
  public static func remove(forDocumentAt url: URL) -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account(forDocumentAt: url),
    ]
    let status = SecItemDelete(query as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
  }
}
