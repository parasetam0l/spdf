import CryptoKit
import Foundation
import ReleaseTools

/// REL-03 CLI: bind a release candidate from the chosen final source. The tool
/// runs read-only checks only; signing, notarization and installation remain
/// owner-gated actions and the gate refuses to present an unverified package as
/// a candidate.
enum CandidateGateCLI {
  static func run(_ command: String, arguments: [String]) throws -> Int32 {
    switch command {
    case "required-checks":
      print(ReleaseGateChecks.requiredIDs.joined(separator: "\n"))
      return 0
    case "candidate-plan":
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
      let plan = ReleaseCandidateDefinition.steps
      FileHandle.standardOutput.write(try encoder.encode(plan))
      print("")
      return 0
    case "candidate-gate":
      return try gate(arguments)
    case "candidate-verify":
      return try verify(arguments)
    default:
      FileHandle.standardError.write(Data("unknown candidate command \(command)\n".utf8))
      return 1
    }
  }

  // MARK: candidate-gate

  private static func gate(_ arguments: [String]) throws -> Int32 {
    let repo = URL(fileURLWithPath: value("--repo", in: arguments) ?? FileManager.default.currentDirectoryPath)
    let sourceSHA: String
    if let provided = value("--source-sha", in: arguments) {
      sourceSHA = provided
    } else {
      sourceSHA = try git(repo, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let sourceTreeClean: Bool
    if hasFlag("--source-dirty", in: arguments) {
      sourceTreeClean = false
    } else if hasFlag("--source-clean", in: arguments) {
      sourceTreeClean = true
    } else {
      let status = try git(repo, ["status", "--porcelain"]).trimmingCharacters(in: .whitespacesAndNewlines)
      sourceTreeClean = status.isEmpty
    }
    let appVersion = value("--version", in: arguments)
      ?? (try? appVersionFromProject(repo)) ?? ""
    let buildVersion = value("--build-version", in: arguments) ?? ""
    let checks: [ReleaseGateCheck]
    if let checksPath = value("--checks", in: arguments) {
      checks = try JSONDecoder().decode(
        [ReleaseGateCheck].self, from: Data(contentsOf: URL(fileURLWithPath: checksPath)))
    } else {
      checks = []
    }
    let environment = inspectEnvironment(arguments)
    let package = try inspectPackage(arguments, environment: environment)
    let manifest = try ReleaseCandidateGate.makeManifest(
      sourceSHA: sourceSHA, appVersion: appVersion, buildVersion: buildVersion,
      sourceTreeClean: sourceTreeClean, checks: checks, package: package,
      environment: environment)
    let evaluation = try ReleaseCandidateGate.validate(
      manifest, expectedSourceSHA: value("--expect-source", in: arguments),
      expectedAppVersion: value("--expect-version", in: arguments))
    let outPath = value("--out", in: arguments)
    if let outPath {
      try ReleaseCandidateGate.write(manifest, to: URL(fileURLWithPath: outPath))
    }
    printManifestResult(manifest, evaluation: evaluation, outPath: outPath)
    return exitCode(for: evaluation)
  }

  // MARK: candidate-verify

  private static func verify(_ arguments: [String]) throws -> Int32 {
    guard let path = arguments.first(where: { !$0.hasPrefix("--") }) else {
      FileHandle.standardError.write(Data("usage: candidate-verify <manifest.json> [--expect-source <sha>] [--expect-version <v>] [--expect-package-sha256 <hex>]\n".utf8))
      return 1
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let manifest = try ReleaseCandidateGate.load(data: data)
    let expectedPackage = value("--expect-package-sha256", in: arguments)
    if let expectedPackage, let package = manifest.package, package.sha256 != expectedPackage {
      FileHandle.standardError.write(Data("error: package digest does not match the expected digest\n".utf8))
    }
    let evaluation = try ReleaseCandidateGate.validate(
      manifest, expectedSourceSHA: value("--expect-source", in: arguments),
      expectedAppVersion: value("--expect-version", in: arguments),
      expectedPackageSHA256: expectedPackage)
    printManifestResult(manifest, evaluation: evaluation, outPath: path)
    return exitCode(for: evaluation)
  }

  // MARK: Output

  private static func printManifestResult(
    _ manifest: ReleaseCandidateManifest, evaluation: ReleaseGateEvaluation, outPath: String?
  ) {
    print("profile: \(manifest.profileIdentifier)")
    print("source-sha: \(manifest.sourceSHA)")
    print("app-version: \(manifest.appVersion)")
    print("manifest-sha256: \(manifest.manifestSHA256)")
    if let package = manifest.package {
      print("package-sha256: \(package.sha256)")
      print("package-path: \(package.path)")
    } else {
      print("package: none")
    }
    print("disposition: \(evaluation.disposition.rawValue)")
    print("owner-action-required: \(evaluation.ownerActionRequired)")
    if !evaluation.blockers.isEmpty {
      print("blockers:")
      for blocker in evaluation.blockers {
        print("- \(blocker.rawValue): \(blocker.title)")
      }
    }
    print("summary: \(evaluation.summary)")
    if let outPath { print("manifest-path: \(outPath)") }
  }

  private static func exitCode(for evaluation: ReleaseGateEvaluation) -> Int32 {
    switch evaluation.disposition {
    case .verified: return 0
    case .readyForOwnerSigning: return 3
    case .refused: return 2
    }
  }

  // MARK: Environment

  private static func inspectEnvironment(_ arguments: [String]) -> ReleaseSigningEnvironment {
    var identityCount = 0
    if let result = try? run(
      "/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
    {
      identityCount = result.output.split(whereSeparator: \.isNewline).filter { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let close = trimmed.firstIndex(of: ")") else { return false }
        return Int(trimmed[trimmed.startIndex..<close]) != nil
      }.count
    }
    let environment = ProcessInfo.processInfo.environment
    let notaryConfigured =
      hasFlag("--notary-configured", in: arguments)
      || !(environment["NOTARY_APPLE_ID"] ?? "").isEmpty
      || !(environment["NOTARY_PASSWORD"] ?? "").isEmpty
      || !(environment["AC_PASSWORD"] ?? "").isEmpty
    return ReleaseSigningEnvironment(
      signingIdentityCount: identityCount,
      notaryCredentialsConfigured: notaryConfigured,
      codesignAvailable: FileManager.default.isExecutableFile(atPath: "/usr/bin/codesign"),
      staplerAvailable: FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun"),
      gatekeeperAvailable: FileManager.default.isExecutableFile(atPath: "/usr/sbin/spctl"))
  }

  // MARK: Package inspection

  private static func inspectPackage(
    _ arguments: [String], environment: ReleaseSigningEnvironment
  ) throws -> ReleaseCandidatePackage? {
    guard let packagePath = value("--package", in: arguments) else { return nil }
    let url = URL(fileURLWithPath: packagePath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ReleaseToolsError.invalid("the package path does not exist: \(packagePath)")
    }
    let digest = try sha256(of: url)
    let sourceSHA = value("--package-source-sha", in: arguments) ?? ""
    let declaredVersion = value("--package-version", in: arguments) ?? ""
    var signatureVerified = false
    var teamIdentifier = ""
    if environment.codesignAvailable {
      let verify = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path])
      signatureVerified = verify.status == 0
      if signatureVerified {
        let details = try run("/usr/bin/codesign", ["-dv", "--verbose=4", url.path])
        for line in details.output.split(whereSeparator: \.isNewline) {
          let text = String(line)
          if text.hasPrefix("TeamIdentifier=") {
            teamIdentifier = String(text.dropFirst("TeamIdentifier=".count))
          }
        }
      }
    }
    var notarizationStapled = false
    if environment.staplerAvailable {
      let staple = try run("/usr/bin/xcrun", ["stapler", "validate", url.path])
      notarizationStapled = staple.status == 0
    }
    var gatekeeperAccepted = false
    if environment.gatekeeperAvailable {
      let assessment = try run("/usr/sbin/spctl", ["-a", "-vv", url.path])
      gatekeeperAccepted = assessment.status == 0
    }
    // The package app version is read from the embedded Info.plist when the
    // artifact is an app bundle; otherwise the owner-provided version is bound
    // and disclosed as such in the manifest note.
    var observedVersion = declaredVersion
    if url.pathExtension == "app" {
      let plist = url.appendingPathComponent("Contents/Info.plist")
      if let data = try? Data(contentsOf: plist),
        let object = try? PropertyListSerialization.propertyList(
          from: data, options: [], format: nil) as? [String: Any],
        let version = object["CFBundleShortVersionString"] as? String
      {
        observedVersion = version
      }
    }
    return ReleaseCandidatePackage(
      path: packagePath, sha256: digest, sourceSHA: sourceSHA,
      appVersion: observedVersion, signed: signatureVerified,
      signatureVerified: signatureVerified, notarizationStapled: notarizationStapled,
      gatekeeperAccepted: gatekeeperAccepted, teamIdentifier: teamIdentifier)
  }

  private static func sha256(of url: URL) throws -> String {
    let data = try Data(contentsOf: url, options: .alwaysMapped)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: Helpers

  private static func appVersionFromProject(_ repo: URL) throws -> String {
    let project = repo.appendingPathComponent("project.yml")
    let text = try String(contentsOf: project, encoding: .utf8)
    for line in text.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("MARKETING_VERSION:") else { continue }
      let value = trimmed.dropFirst("MARKETING_VERSION:".count)
        .trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      if !value.isEmpty { return value }
    }
    throw ReleaseToolsError.invalid("MARKETING_VERSION is missing from project.yml")
  }

  private static func git(_ repo: URL, _ arguments: [String]) throws -> String {
    let result = try run("/usr/bin/git", ["-C", repo.path] + arguments)
    guard result.status == 0 else {
      throw ReleaseToolsError.invalid("git \(arguments.joined(separator: " ")) failed")
    }
    return result.output
  }

  private static func run(
    _ executable: String, _ arguments: [String]
  ) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  private static func value(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
      return nil
    }
    return arguments[index + 1]
  }

  private static func hasFlag(_ name: String, in arguments: [String]) -> Bool {
    arguments.contains(name)
  }
}
