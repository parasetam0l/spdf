import Foundation
import PDFCore
import PDFEditing
import PDFFixtures
import Testing
@testable import MacServices

/// P43-002/P43-003/P43-005/P43-006/P43-007/P43-010/P43-012: availability,
/// status warnings, catalog search, bounded preparation from official
/// endpoints, atomic installation, and offline failure behavior.
@Suite("Font provisioning")
struct FontProvisioningTests {
  private func font(
    name: String, embedded: Bool = false, subset: Bool = false
  ) -> PDFDocumentFont {
    PDFDocumentFont(
      resource: "F1", baseName: name, subtype: "Type1", encoding: nil, isEmbedded: embedded,
      isSubset: subset, isType0: false, pageIndices: [0])
  }

  private func http(_ url: URL, _ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
  }

  private func listingJSON(files: [(String, Int)]) -> Data {
    let entries: [[String: Any]] = files.map { name, size in
      [
        "name": name,
        "size": size,
        "download_url": "https://raw.githubusercontent.com/google/fonts/main/ofl/testfamily/\(name)",
      ]
    }
    return (try? JSONSerialization.data(withJSONObject: entries)) ?? Data()
  }

  @Test func systemAvailabilityMatchesCoreText() {
    #expect(FontAvailability.system.isInstalled("Helvetica"))
    #expect(!FontAvailability.system.isInstalled("Nonexistent Font Family XYZ"))
  }

  @Test func statusesAndEditingWarningsFollowAvailability() {
    let missing = font(name: "Custom Sans")
    let unavailable = FontAvailability { _ in false }
    let status = FontProvisioning.status(for: missing, availability: unavailable)
    #expect(status.needsProvisioning)
    #expect(status.stateLabel == "Missing")
    #expect(status.warning?.contains("Helvetica") == true)
    #expect(status.fallback == "Helvetica")
    let warning = FontProvisioning.editingWarning(for: missing, availability: unavailable)
    #expect(warning?.contains("embedded widths") == true)

    let installed = FontProvisioning.status(
      for: missing, availability: FontAvailability { _ in true })
    #expect(installed.installed)
    #expect(!installed.needsProvisioning)
    #expect(installed.warning == nil)
    #expect(
      FontProvisioning.editingWarning(
        for: missing, availability: FontAvailability { _ in true }) == nil)

    // Embedded fonts need no system installation.
    let embedded = FontProvisioning.status(
      for: font(name: "ABCDEF+Custom Sans", embedded: true, subset: true),
      availability: unavailable)
    #expect(!embedded.needsProvisioning)
    #expect(embedded.stateLabel == "Embedded")

    // Commercially licensed fonts are warned about regardless of embedding.
    let paid = FontProvisioning.status(
      for: font(name: "MinionPro-Regular"), availability: unavailable)
    #expect(paid.warning?.contains("commercially licensed") == true)
  }

  @Test func catalogParseSearchAndBounds() throws {
    let json = Data(
      """
      {"familyMetadataList": [
        {"family": "Roboto", "category": "Sans Serif", "isOpenSource": true},
        {"family": "Roboto Mono", "category": "Monospace", "isOpenSource": true},
        {"family": "Rock Salt", "category": "Handwriting", "isOpenSource": true}
      ]}
      """.utf8)
    let families = try GoogleFontsCatalog.parseFamilies(json)
    #expect(families.count == 3)
    let results = GoogleFontsCatalog.search("roboto", in: families)
    #expect(results.map(\.name) == ["Roboto", "Roboto Mono"])
    let prefix = GoogleFontsCatalog.search("rock", in: families)
    #expect(prefix.map(\.name) == ["Rock Salt"])
    #expect(GoogleFontsCatalog.search("", in: families).count == 3)

    let oversized = Data(repeating: 0x20, count: GoogleFontsInstaller.Limits().maxMetadataBytes + 1)
    #expect(throws: FontProvisioningError.self) {
      _ = try GoogleFontsCatalog.parseFamilies(oversized)
    }
  }

  @Test func prepareDownloadsFromOfficialEndpointsWithinBounds() async throws {
    let fontBytes = Data(repeating: 0x41, count: 4_096)
    let requested = LockedBox<[String]>([])
    let client = GoogleFontsClient { url in
      requested.mutate { $0.append(url.absoluteString) }
      switch url.absoluteString {
      case "https://api.github.com/repos/google/fonts/contents/ofl/testfamily":
        return (
          self.listingJSON(files: [
            ("Test-Regular.ttf", 4_096), ("Test-Bold.ttf", 4_096), ("OFL.txt", 1_000),
          ]), self.http(url, 200)
        )
      case "https://raw.githubusercontent.com/google/fonts/main/ofl/testfamily/OFL.txt":
        return (Data("SIL Open Font License 1.1".utf8), self.http(url, 200))
      case "https://raw.githubusercontent.com/google/fonts/main/ofl/testfamily/Test-Regular.ttf":
        return (fontBytes, self.http(url, 200))
      case "https://raw.githubusercontent.com/google/fonts/main/ofl/testfamily/Test-Bold.ttf":
        return (fontBytes, self.http(url, 200))
      default:
        return (Data(), self.http(url, 404))
      }
    }
    let package = try await GoogleFontsInstaller.prepare(family: "Test Family", client: client)
    #expect(package.family == "Test Family")
    #expect(package.files.count == 2)
    #expect(package.files.allSatisfy { $0.data == fontBytes })
    #expect(package.licenseText?.contains("SIL Open Font License") == true)
    #expect(requested.value.allSatisfy {
      $0.hasPrefix("https://api.github.com/") || $0.hasPrefix("https://raw.githubusercontent.com/")
    })
  }

  @Test func prepareEnforcesFileCountAndSizeBounds() async throws {
    let bigFile = 30 * 1_024 * 1_024
    let client = GoogleFontsClient { url in
      switch url.absoluteString {
      case "https://api.github.com/repos/google/fonts/contents/ofl/testfamily":
        return (
          self.listingJSON(files: [("Huge.ttf", bigFile), ("OFL.txt", 100)]),
          self.http(url, 200)
        )
      case "https://raw.githubusercontent.com/google/fonts/main/ofl/testfamily/OFL.txt":
        return (Data("OFL".utf8), self.http(url, 200))
      default:
        return (Data(), self.http(url, 404))
      }
    }
    // The oversized file is skipped and no installable file remains.
    await #expect(throws: FontProvisioningError.self) {
      _ = try await GoogleFontsInstaller.prepare(
        family: "Test Family", client: client,
        limits: GoogleFontsInstaller.Limits(maxFileBytes: 1_024))
    }
  }

  @Test func prepareSurfacesOfflineFailures() async {
    let client = GoogleFontsClient { _ in
      throw URLError(.notConnectedToInternet)
    }
    await #expect(throws: URLError.self) {
      _ = try await GoogleFontsInstaller.prepare(family: "Test Family", client: client)
    }
  }

  @Test func installedFontResolvesWarningAndMetricsStayDocumentDriven() throws {
    // After provisioning, the warning clears; the document's own widths keep
    // driving edits, so metrics do not change with the system font.
    let font = font(name: "Custom Sans")
    let before = FontProvisioning.status(
      for: font, availability: FontAvailability { _ in false })
    #expect(before.needsProvisioning)
    let after = FontProvisioning.status(
      for: font, availability: FontAvailability { _ in true })
    #expect(!after.needsProvisioning && after.warning == nil)
    #expect(before.fallback == after.fallback)
    // Provisioning changes availability only; the document facts (and the
    // widths edits rely on) are untouched.
    #expect(before.font == after.font)
  }

  @Test func catalogParseCostStaysBounded() throws {
    // A catalog the size of the live Google Fonts metadata (about 1,950
    // families) parses well inside the bound.
    var entries: [[String: Any]] = []
    for index in 0..<1_950 {
      entries.append([
        "family": "Family \(index)", "category": "Sans Serif", "isOpenSource": true,
      ])
    }
    let data = try JSONSerialization.data(
      withJSONObject: ["familyMetadataList": entries])
    print("[P43-012] catalog payload: \(data.count / 1_024) KiB")
    let start = ContinuousClock.now
    let families = try GoogleFontsCatalog.parseFamilies(data)
    let duration = ContinuousClock.now - start
    let milliseconds = duration.components.seconds * 1000
      + duration.components.attoseconds / 1_000_000_000_000_000
    print("[P43-012] catalog parse: \(milliseconds) ms for \(families.count) families")
    #expect(families.count == 1_950)
    #expect(duration < .seconds(2))
  }

  @Test func installCopiesAtomicallyAndRequiresLicense() throws {
    let package = GoogleFontPackage(
      family: "Test Family",
      files: [GoogleFontFile(name: "Test-Regular.ttf", data: Data([1, 2, 3]))],
      licenseText: "OFL", licenseDirectory: "ofl")
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-fonts-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let urls = try GoogleFontsInstaller.install(package, to: directory, licenseAccepted: true)
    #expect(urls.count == 1)
    #expect(try Data(contentsOf: urls[0]) == Data([1, 2, 3]))
    #expect(throws: FontProvisioningError.self) {
      _ = try GoogleFontsInstaller.install(package, to: directory, licenseAccepted: false)
    }
    #expect(try Data(contentsOf: urls[0]) == Data([1, 2, 3]))
  }

  @Test func installRefusesToReplaceAnExistingFont() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-font-conflict-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let existing = directory.appendingPathComponent("a.ttf")
    try Data([9, 8, 7]).write(to: existing)
    let package = GoogleFontPackage(
      family: "Test Family",
      files: [
        GoogleFontFile(name: "a.ttf", data: Data([1])),
        GoogleFontFile(name: "b.ttf", data: Data([2])),
      ], licenseText: "OFL", licenseDirectory: "ofl")

    #expect(throws: FontProvisioningError.self) {
      _ = try GoogleFontsInstaller.install(package, to: directory, licenseAccepted: true)
    }
    #expect(try Data(contentsOf: existing) == Data([9, 8, 7]))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("b.ttf").path))
  }

  @Test func provisionedFontsRequireAnAcceptedRecordAndUnchangedBytes() throws {
    let program = try #require(Data(base64Encoded: FontFixtureData.subsetProgramBase64))
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-font-record-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fontURL = directory.appendingPathComponent("Fixture-Regular.ttf")
    try program.write(to: fontURL)
    let package = GoogleFontPackage(
      family: "Fixture Family",
      files: [GoogleFontFile(name: fontURL.lastPathComponent, data: program)],
      licenseText: "SIL Open Font License", licenseDirectory: "ofl")

    try ProvisionedFontStore.recordAccepted(package, installed: [fontURL], in: directory)
    let available = ProvisionedFontStore.availableFonts(in: directory)
    #expect(available.count == 1)
    #expect(available.first?.familyName == "Fixture Family")
    #expect(available.first?.program == program)

    try Data([1, 2, 3]).write(to: fontURL, options: .atomic)
    #expect(ProvisionedFontStore.availableFonts(in: directory).isEmpty)
  }

  @Test func installCleansUpOnFailure() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-fonts-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // A directory where the second file must go forces a mid-install failure.
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("b.ttf"), withIntermediateDirectories: false)
    let package = GoogleFontPackage(
      family: "Test Family",
      files: [
        GoogleFontFile(name: "a.ttf", data: Data([1])),
        GoogleFontFile(name: "b.ttf", data: Data([2])),
      ], licenseText: "OFL", licenseDirectory: "ofl")
    #expect(throws: (any Error).self) {
      _ = try GoogleFontsInstaller.install(package, to: directory, licenseAccepted: true)
    }
    // The first file must not remain after the failure (no partial install).
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("a.ttf").path))
  }
}

/// Small thread-safe box for recording requests in stubs.
final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value

  init(_ value: Value) { storage = value }

  var value: Value {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func mutate(_ body: (inout Value) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    body(&storage)
  }
}
