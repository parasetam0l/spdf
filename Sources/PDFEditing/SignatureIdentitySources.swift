import CryptoKit
import Foundation
import PDFCore
import Security

/// SIG-07: broader signing identity sources. The catalog enumerates identities
/// through Security framework APIs only; private keys stay in their Keychain or
/// hardware-token store and are never copied into our models. Certificate files
/// can be added explicitly: a certificate-only import is selectable for
/// inspection but cannot sign, while a PKCS#12 import places the identity in the
/// user's Keychain (the intended private-key store) through SecPKCS12Import.

public enum PDFSigningIdentityKind: String, Sendable, Equatable {
  /// A software private key in the user's Keychain.
  case keychain
  /// A Secure Enclave-backed key.
  case secureEnclave
  /// A key held by a hardware token/smart card exposed through Security.
  case hardwareToken
  /// An identity the user explicitly imported from a PKCS#12 file.
  case importedPKCS12
  /// A certificate file with no private key: inspectable, not usable for signing.
  case certificateOnly

  public var displayName: String {
    switch self {
    case .keychain: return "Keychain"
    case .secureEnclave: return "Secure Enclave"
    case .hardwareToken: return "Hardware token"
    case .importedPKCS12: return "Imported PKCS#12"
    case .certificateOnly: return "Certificate only"
    }
  }

  public var isHardwareBacked: Bool {
    self == .secureEnclave || self == .hardwareToken
  }

  public var canHoldPrivateKey: Bool { self != .certificateOnly }
}

public struct PDFSigningIdentitySource: @unchecked Sendable {
  public let kind: PDFSigningIdentityKind
  public let certificate: SecCertificate
  public let identity: SecIdentity?
  public let commonName: String
  public let organization: String?
  public let issuerCommonName: String?
  public let notBefore: Date?
  public let notAfter: Date?
  public let fingerprintSHA256: String
  public let origin: String?
  public let tokenID: String?
  public let keyAlgorithm: String?
  public let privateKeyAvailable: Bool
  public let unavailableReason: String?

  public var canSign: Bool {
    identity != nil && privateKeyAvailable && kind.canHoldPrivateKey
  }

  public var displayName: String { commonName }

  public var sourceDescription: String {
    var parts: [String] = [kind.displayName]
    if let tokenID, kind.isHardwareBacked {
      parts.append(tokenID)
    }
    if let origin {
      parts.append(origin)
    }
    if let keyAlgorithm {
      parts.append(keyAlgorithm)
    }
    return parts.joined(separator: " · ")
  }

  public var validityDescription: String {
    guard let notBefore, let notAfter else { return "Validity unavailable" }
    return "Valid " + notBefore.formatted(date: .abbreviated, time: .omitted)
      + " – " + notAfter.formatted(date: .abbreviated, time: .omitted)
  }

  public var selectionWarning: String? {
    if let unavailableReason { return unavailableReason }
    if !canSign {
      return kind == .certificateOnly
        ? "Certificate only — no private key; cannot sign. Import a PKCS#12 to sign."
        : "This source cannot sign; choose a keychain, token or PKCS#12 identity."
    }
    return nil
  }

  /// Resolve the Security identity for an explicit signing action. Throws
  /// before any output file is created when the selection cannot sign (for
  /// example a certificate-only import or an unavailable token), so a cancelled
  /// or unusable selection never leaves a partial signed file.
  public func signingIdentity() throws -> SecIdentity {
    guard canSign, let identity else {
      throw PDFError(
        .unsupported,
        selectionWarning ?? "The selected identity has no usable private key")
    }
    return identity
  }
}

public enum PDFSigningIdentityCatalog {
  /// Enumerate identities visible through the Security framework. Token-backed
  /// keys appear here when their token is available; secure-enclave/token
  /// classification uses keychain token attributes without copying keys.
  /// Passing explicit keychains is a test seam; production uses the default
  /// keychain search list.
  public static func available(searchKeychains: [SecKeychain] = []) -> [PDFSigningIdentitySource] {
    let identityQuery = identityQuery(searchKeychains: searchKeychains)
    var result: CFTypeRef?
    guard SecItemCopyMatching(identityQuery as CFDictionary, &result) == errSecSuccess,
      let identities = result as? [SecIdentity]
    else { return [] }
    let keyAttributes = privateKeyAttributes(searchKeychains: searchKeychains)
    return identities.compactMap { identity in
      guard let certificate = certificate(of: identity) else { return nil }
      let label = publicKeyLabel(certificate: certificate)
      let attrs = label.flatMap { keyAttributes[$0] }
      return makeSource(
        identity: identity, certificate: certificate, origin: nil,
        importKind: nil, keyAttributes: attrs)
    }.sorted {
      ($0.commonName.localizedCaseInsensitiveCompare($1.commonName) == .orderedAscending)
    }
  }

  static func identityQuery(searchKeychains: [SecKeychain]) -> [CFString: Any] {
    var query: [CFString: Any] = [
      kSecClass: kSecClassIdentity,
      kSecMatchLimit: kSecMatchLimitAll,
      kSecReturnRef: true,
    ]
    if !searchKeychains.isEmpty {
      query[kSecMatchSearchList] = searchKeychains
    }
    return query
  }

  /// Application label -> private-key attribute dictionary. No key material is
  /// read and no token PIN is requested.
  static func privateKeyAttributes(searchKeychains: [SecKeychain]) -> [Data: [CFString: Any]] {
    var query: [CFString: Any] = [
      kSecClass: kSecClassKey,
      kSecAttrKeyClass: kSecAttrKeyClassPrivate,
      kSecMatchLimit: kSecMatchLimitAll,
      kSecReturnAttributes: true,
    ]
    if !searchKeychains.isEmpty {
      query[kSecMatchSearchList] = searchKeychains
    }
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let attributes = result as? [[CFString: Any]]
    else { return [:] }
    var byLabel: [Data: [CFString: Any]] = [:]
    for entry in attributes {
      guard let label = entry[kSecAttrApplicationLabel] as? Data else { continue }
      byLabel[label] = entry
    }
    return byLabel
  }

  static func publicKeyLabel(certificate: SecCertificate) -> Data? {
    let der = SecCertificateCopyData(certificate) as Data
    guard let fields = try? X509CertificateFields.parse(der) else { return nil }
    return Data(Insecure.SHA1.hash(data: fields.subjectPublicKeyBits))
  }

  static func certificate(of identity: SecIdentity) -> SecCertificate? {
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess else { return nil }
    return certificate
  }

  static func fingerprint(of certificate: SecCertificate) -> String {
    let der = SecCertificateCopyData(certificate) as Data
    return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
  }

  static func certificateOnlySource(
    certificate: SecCertificate, origin: String?
  ) -> PDFSigningIdentitySource {
    makeSource(
      identity: nil, certificate: certificate, origin: origin,
      importKind: .certificateOnly, keyAttributes: nil)
  }

  static func kind(tokenID: String?, importKind: PDFSigningIdentityKind?) -> PDFSigningIdentityKind {
    if let tokenID, !tokenID.isEmpty {
      if tokenID == (kSecAttrTokenIDSecureEnclave as String) {
        return .secureEnclave
      }
      return .hardwareToken
    }
    if let importKind { return importKind }
    return .keychain
  }

  /// Classify one already-known Security identity, for callers that keep their
  /// own identity list (for example the existing signing flow).
  public static func source(for identity: SecIdentity) -> PDFSigningIdentitySource? {
    guard let certificate = certificate(of: identity) else { return nil }
    let keyAttributes = privateKeyAttributes(searchKeychains: [])
    let attrs = publicKeyLabel(certificate: certificate).flatMap { keyAttributes[$0] }
    return makeSource(
      identity: identity, certificate: certificate, origin: nil,
      importKind: nil, keyAttributes: attrs)
  }

  /// Import an explicit certificate file or PKCS#12 identity.
  ///
  /// - PKCS#12: SecPKCS12Import places the private key in the user's Keychain
  ///   (or an injected test keychain); the app keeps only the returned
  ///   Security identity reference. A missing/wrong passphrase throws
  ///   passwordRequired/incorrectPassword without writing any other state.
  /// - Certificate files (.cer/.crt/.der/.pem): parsed with
  ///   SecCertificateCreateWithData after bounded PEM/DER decoding. The result
  ///   is certificate-only and cannot sign.
  public static func importFile(
    at url: URL, passphrase: String?, destinationKeychain: SecKeychain? = nil,
    limits: PDFLimits = PDFLimits()
  ) throws -> PDFSigningIdentitySource {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let fileSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    guard fileSize > 0 else {
      throw PDFError(.malformed, "The identity file is empty")
    }
    guard fileSize <= limits.streamBytes else {
      throw PDFError(.limitExceeded, "The identity file exceeds the configured limit")
    }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw PDFError(
        .malformed, "The identity file could not be read: " + error.localizedDescription)
    }
    let pathExtension = url.pathExtension.lowercased()
    if pathExtension == "p12" || pathExtension == "pfx" {
      guard let passphrase, !passphrase.isEmpty else {
        throw PDFError(.passwordRequired, "This PKCS#12 identity needs its passphrase")
      }
      return try importPKCS12(
        data, passphrase: passphrase, origin: url.lastPathComponent,
        destinationKeychain: destinationKeychain)
    }
    if ["cer", "crt", "der", "pem", "cert"].contains(pathExtension) {
      let certificate = try parseCertificateFile(data)
      return certificateOnlySource(
        certificate: certificate, origin: url.lastPathComponent)
    }
    throw PDFError(
      .unsupported,
      "Unsupported identity file type ." + pathExtension
        + "; choose a PKCS#12 (.p12/.pfx) or a certificate (.cer/.crt/.der/.pem)")
  }

  static func importPKCS12(
    _ data: Data, passphrase: String, origin: String,
    destinationKeychain: SecKeychain?
  ) throws -> PDFSigningIdentitySource {
    var options: [CFString: Any] = [
      kSecImportExportPassphrase: passphrase,
    ]
    if let destinationKeychain {
      options[kSecImportExportKeychain] = destinationKeychain
    }
    var items: CFArray?
    let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
    guard status == errSecSuccess else {
      throw importError(status: status)
    }
    guard let array = items as? [[String: Any]] else {
      throw PDFError(.unsupported, "The PKCS#12 import returned no items")
    }
    let searchKeychains = destinationKeychain.map { [$0] } ?? []
    let keyAttributes = privateKeyAttributes(searchKeychains: searchKeychains)
    for item in array {
      guard let rawIdentity = item[kSecImportItemIdentity as String],
        CFGetTypeID(rawIdentity as CFTypeRef) == SecIdentityGetTypeID()
      else { continue }
      let identity: SecIdentity = rawIdentity as! SecIdentity
      guard let certificate = certificate(of: identity) else { continue }
      let attrs = publicKeyLabel(certificate: certificate).flatMap { keyAttributes[$0] }
      return makeSource(
        identity: identity, certificate: certificate, origin: origin,
        importKind: .importedPKCS12, keyAttributes: attrs)
    }
    // A PKCS#12 can contain certificates without a private key; it is then
    // inspectable but not usable for signing.
    if let chain = array.compactMap({
      $0[kSecImportItemCertChain as String] as? [SecCertificate]
    }).first, let leaf = chain.first {
      return certificateOnlySource(certificate: leaf, origin: origin)
    }
    throw PDFError(.unsupported, "The PKCS#12 file contains no certificate identity")
  }

  static func importError(status: OSStatus) -> PDFError {
    if status == errSecAuthFailed || status == errSecPkcs12VerifyFailure {
      return PDFError(.incorrectPassword, "The PKCS#12 passphrase is not correct")
    }
    let message = SecCopyErrorMessageString(status, nil) as String?
      ?? "OSStatus " + String(status)
    return PDFError(.unsupported, "The PKCS#12 identity could not be imported: " + message)
  }

  static func parseCertificateFile(_ data: Data) throws -> SecCertificate {
    if let certificate = SecCertificateCreateWithData(nil, data as CFData) {
      return certificate
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw PDFError(.unsupported, "The certificate file is not DER or PEM encoded")
    }
    var payload = ""
    var insideCertificate = false
    for line in text.split(whereSeparator: { $0.isNewline }) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.contains("BEGIN CERTIFICATE") {
        insideCertificate = true
        continue
      }
      if trimmed.contains("END CERTIFICATE") {
        break
      }
      if insideCertificate {
        payload += trimmed
      }
    }
    if let der = Data(base64Encoded: payload),
      let certificate = SecCertificateCreateWithData(nil, der as CFData)
    {
      return certificate
    }
    throw PDFError(.unsupported, "The file does not contain a readable X.509 certificate")
  }

  static func makeSource(
    identity: SecIdentity?, certificate: SecCertificate, origin: String?,
    importKind: PDFSigningIdentityKind?, keyAttributes: [CFString: Any]?
  ) -> PDFSigningIdentitySource {
    let details = PDFSignatureSignerIdentity.certificateDetails(certificate)
    let tokenID = keyAttributes?[kSecAttrTokenID] as? String
    let rawKeyType = keyAttributes?[kSecAttrKeyType] as? String
    let keyAlgorithm: String?
    if rawKeyType == (kSecAttrKeyTypeRSA as String) {
      keyAlgorithm = "RSA"
    } else if rawKeyType == (kSecAttrKeyTypeECSECPrimeRandom as String) {
      keyAlgorithm = "EC"
    } else {
      keyAlgorithm = nil
    }
    let kind = kind(tokenID: tokenID, importKind: identity == nil ? .certificateOnly : importKind)
    let privateKeyAvailable = identity != nil
    return PDFSigningIdentitySource(
      kind: kind,
      certificate: certificate,
      identity: identity,
      commonName: details?.commonName
        ?? (SecCertificateCopySubjectSummary(certificate) as String?)
        ?? "Unnamed certificate",
      organization: details?.organization,
      issuerCommonName: details?.issuerCommonName,
      notBefore: details?.notBefore,
      notAfter: details?.notAfter,
      fingerprintSHA256: fingerprint(of: certificate),
      origin: origin,
      tokenID: tokenID,
      keyAlgorithm: keyAlgorithm,
      privateKeyAvailable: privateKeyAvailable,
      unavailableReason: identity == nil
        ? "Certificate only — no private key; cannot sign." : nil)
  }
}
