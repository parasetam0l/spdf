import Foundation
import ReleaseTools

// Command-line surface for the release workflows (P42-009). Every
// subcommand prints a clear error and exits non-zero on invalid input.

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("error: \(message)\n".utf8))
  exit(1)
}

func argument(_ name: String, in arguments: [String]) -> String? {
  guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
    return nil
  }
  return arguments[index + 1]
}

func required(_ name: String, in arguments: [String]) -> String {
  if let value = argument(name, in: arguments) { return value }
  fail("missing \(name)")
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
  fail("usage: release-tools <verify-signature|appcast|validate-appcast|notary-check|manifest|release-date|release-field|release-body|next-build|check-build|corpus-matrix>")
}

do {
  switch command {
  case "verify-signature":
    // verify-signature <public-key-base64> <signature-base64> <file>
    guard arguments.count == 4 else { fail("usage: verify-signature <key> <signature> <file>") }
    let valid = try UpdateSignature.verify(
      publicKeyBase64: arguments[1], signatureBase64: arguments[2],
      fileURL: URL(fileURLWithPath: arguments[3]))
    guard valid else { fail("the signature does not match the file") }
    print("The signature matches the app's public key.")

  case "appcast":
    // appcast --title ... --version ... --short-version ... --minimum-system ...
    //   --published <iso8601> --dmg-url ... --dmg-path ... --signature ...
    //   --notes-html <file> --release-url ... [--feed-title ...] [--feed-link ...]
    let dmgPath = required("--dmg-path", in: arguments)
    let notesPath = argument("--notes-html", in: arguments)
    let notes = try notesPath.map { try String(contentsOfFile: $0, encoding: .utf8) } ?? ""
    let published: Date
    if let raw = argument("--published", in: arguments), !raw.isEmpty {
      let formatter = ISO8601DateFormatter()
      guard let date = formatter.date(from: raw) else { fail("--published is not ISO 8601") }
      published = date
    } else {
      published = Date()
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: dmgPath)
    guard let assetLength = (attributes[.size] as? NSNumber)?.intValue else {
      fail("cannot read the DMG size")
    }
    let item = AppcastItem(
      title: required("--title", in: arguments),
      published: published,
      buildVersion: required("--version", in: arguments),
      shortVersion: required("--short-version", in: arguments),
      minimumSystemVersion: required("--minimum-system", in: arguments),
      releaseNotesHTML: notes,
      releaseNotesLink: required("--release-url", in: arguments),
      assetURL: required("--dmg-url", in: arguments),
      assetLength: assetLength,
      edSignature: required("--signature", in: arguments))
    print(
      Appcast.xml(
        feedTitle: argument("--feed-title", in: arguments) ?? "sPDF Editor",
        feedLink: argument("--feed-link", in: arguments)
          ?? "https://github.com/parasetam0l/spdf/releases",
        item: item))

  case "validate-appcast":
    guard arguments.count >= 2 else { fail("usage: validate-appcast <file> [--dmg-path ...] [--public-key ...]") }
    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    let entries = try AppcastValidator.validate(
      data: data,
      assetURL: argument("--dmg-path", in: arguments).map(URL.init(fileURLWithPath:)),
      publicKeyBase64: argument("--public-key", in: arguments))
    print("The appcast is valid (\(entries.count) item(s)).")

  case "notary-check":
    guard arguments.count == 2 else { fail("usage: notary-check <json-file>") }
    let result = try NotaryResult.parse(try Data(contentsOf: URL(fileURLWithPath: arguments[1])))
    print("id=\(result.submissionID) status=\(result.status)")
    guard result.status == "Accepted" else {
      fail("notarization ended with status '\(result.status)' (id \(result.submissionID))")
    }

  case "manifest":
    let manifest = try ReleaseManifestBuilder.make(
      appURL: URL(fileURLWithPath: required("--app", in: arguments)),
      assetURL: URL(fileURLWithPath: required("--dmg", in: arguments)),
      assetRemoteURL: required("--dmg-url", in: arguments),
      signature: required("--signature", in: arguments))
    FileHandle.standardOutput.write(try ReleaseManifestBuilder.json(manifest))

  case "release-date":
    guard arguments.count == 2 else { fail("usage: release-date <release.json>") }
    print(try ReleaseDate.iso8601(from: Data(contentsOf: URL(fileURLWithPath: arguments[1]))))

  case "release-field":
    // release-field <release.json> <field>
    guard arguments.count == 3 else { fail("usage: release-field <json> <field>") }
    guard let object = try JSONSerialization.jsonObject(
      with: Data(contentsOf: URL(fileURLWithPath: arguments[1]))) as? [String: Any],
      let value = object[arguments[2]] as? String
    else { fail("field \(arguments[2]) is missing") }
    print(value)

  case "release-body":
    // release-body <release.json> <output-file>
    guard arguments.count == 3 else { fail("usage: release-body <json> <output>") }
    guard let object = try JSONSerialization.jsonObject(
      with: Data(contentsOf: URL(fileURLWithPath: arguments[1]))) as? [String: Any],
      let body = object["body"] as? String
    else { fail("the release body is missing") }
    try body.write(toFile: arguments[2], atomically: true, encoding: .utf8)

  case "next-build":
    // next-build --previous <csv-builds> [--now <epoch>]
    // Prints the monotonic build number above every previous published build.
    let previous = argument("--previous", in: arguments) ?? ""
    let builds = previous.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    let now: Int
    if let raw = argument("--now", in: arguments), let value = Int(raw) {
      now = value
    } else {
      now = Int(Date().timeIntervalSince1970)
    }
    print(BuildVersionPolicy.nextBuild(after: builds, now: now))

  case "check-build":
    // check-build --build <n> --previous <csv-builds> [--tags <csv>] [--tag <vX>]
    // Refuses duplicate/moved tags and non-monotonic builds.
    let build = required("--build", in: arguments)
    let previous = argument("--previous", in: arguments) ?? ""
    let builds = previous.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    if let tag = argument("--tag", in: arguments) {
      let tags = (argument("--tags", in: arguments) ?? "")
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      if BuildVersionPolicy.isDuplicateTag(tag, existingTags: tags) {
        fail("release tag \(tag) already exists")
      }
    }
    guard BuildVersionPolicy.isMonotonic(build, after: builds) else {
      fail("build \(build) is not above the previous published builds (\(previous))")
    }
    print("Build \(build) is monotonic.")

  case "corpus-matrix":
    // corpus-matrix --manifest <Work/Corpus/manifest.json>
    // Validates the private-corpus manifest (P03-023) and prints the
    // producer/version/feature matrix (P38-025). The manifest itself stays
    // under ignored Work/; only counts and group keys are printed, never
    // document content.
    let manifestPath = required("--manifest", in: arguments)
    let manifestData = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
    let manifest = try CorpusManifest.load(data: manifestData)
    print(CorpusMatrix.build(from: manifest).report())

  case "candidate-gate", "candidate-verify", "candidate-plan", "required-checks":
    exit(try CandidateGateCLI.run(command, arguments: Array(arguments.dropFirst())))

  default:
    fail("unknown command \(command)")
  }
} catch {
  fail("\(error)")
}
