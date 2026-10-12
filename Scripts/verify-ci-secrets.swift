#!/usr/bin/env swift
// Validates local release credentials without printing them or importing
// a certificate into the login keychain. Passwords arrive through stdin.
import CryptoKit
import Foundation
import Security

func reject(_ message: String) -> Never {
  FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
  exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
  switch arguments.first {
  case "sparkle":
    guard arguments.count == 4 else { reject("usage: sparkle <key-file> <Info.plist> <owner/repo>") }
    let plistData = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    guard let plist = try PropertyListSerialization.propertyList(
      from: plistData, format: nil) as? [String: Any],
      let expectedKey = plist["SUPublicEDKey"] as? String,
      plist["SUFeedURL"] as? String
        == "https://github.com/\(arguments[3])/releases/latest/download/appcast.xml"
    else { reject("The app's Sparkle feed does not match the target repository.") }
    let encodedSeed = try String(contentsOfFile: arguments[1], encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let seed = Data(base64Encoded: encodedSeed), seed.count == 32
    else { reject("The Sparkle key file must contain a base64-encoded 32-byte private seed.") }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    guard key.publicKey.rawRepresentation.base64EncodedString() == expectedKey
    else { reject("The Sparkle private key does not match the app's public key.") }
    print("Sparkle key matches the app's public key and repository feed.")

  case "p12":
    guard arguments.count == 3 else { reject("usage: p12 <certificate.p12> <team-id>") }
    guard #available(macOS 15.0, *) else {
      reject("Certificate validation without keychain imports requires macOS 15 or later.")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    guard data.base64EncodedData().count <= 48 * 1024
    else { reject("The encoded certificate exceeds GitHub's 48 KiB secret limit.") }
    guard let password = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
    else { reject("The certificate password is not UTF-8.") }
    let options = [
      kSecImportExportPassphrase as String: password,
      kSecImportToMemoryOnly as String: true,
    ] as [String: Any]
    var imported: CFArray?
    let status = SecPKCS12Import(data as CFData, options as CFDictionary, &imported)
    guard status == errSecSuccess,
      let identities = imported as? [[String: Any]], identities.count == 1,
      let identityValue = identities[0][kSecImportItemIdentity as String]
    else { reject("Cannot read one certificate and private key from the .p12; check its password and export.") }
    let identity = identityValue as! SecIdentity
    var certificate: SecCertificate?
    var privateKey: SecKey?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
      SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess,
      let certificate, privateKey != nil,
      let name = SecCertificateCopySubjectSummary(certificate) as String?,
      name.hasPrefix("Developer ID Application:"), name.hasSuffix("(\(arguments[2]))")
    else { reject("The .p12 must contain a Developer ID Application identity for team \(arguments[2]).") }
    print("Developer ID certificate and private key match the release team.")

  default:
    reject("Choose sparkle or p12 validation.")
  }
} catch {
  // Deliberately omit underlying errors, which may include credential data.
  reject("Cannot read or validate the selected credential file.")
}
