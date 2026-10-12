import CoreText
import Foundation
import PDFCore
import PDFEditing

/// P43-002/P43-007: whether a font family resolves on this system. The check
/// is injectable so tests never depend on what is installed.
public struct FontAvailability: Sendable {
  public let isInstalled: @Sendable (String) -> Bool

  public init(isInstalled: @escaping @Sendable (String) -> Bool) {
    self.isInstalled = isInstalled
  }

  /// Exact-name matching through CoreText: a missing family yields no
  /// descriptor matches instead of a silent substitution.
  public static let system = FontAvailability { name in
    let descriptor = CTFontDescriptorCreateWithNameAndSize(name as CFString, 12)
    let matches =
      CTFontDescriptorCreateMatchingFontDescriptors(descriptor, nil) as? [CTFontDescriptor]
      ?? []
    return !matches.isEmpty
  }
}

/// P43-002/P43-003/P43-004: the provisioning status of one document font.
public struct FontStatus: Sendable, Equatable {
  public let font: PDFDocumentFont
  public let installed: Bool
  /// True when the document does not embed the font and the system lacks it.
  public let needsProvisioning: Bool
  public let warning: String?
  public let fallback: String

  public var stateLabel: String {
    if font.isType3 { return "Type 3" }
    if font.isEmbedded { return "Embedded" }
    if installed { return "Installed" }
    return "Missing"
  }
}

public enum FontProvisioning {
  public static func status(
    for font: PDFDocumentFont, availability: FontAvailability = .system
  ) -> FontStatus {
    let installed = availability.isInstalled(font.familyName)
    let needsProvisioning = !installed && !font.isEmbedded && !font.isStandard14
    var warning: String?
    if font.isType3 {
      var text =
        "“\(font.familyName)” is a Type 3 font: its text is readable, but editing refuses because the glyph programs are preserved, never rewritten."
      if needsProvisioning {
        text +=
          " The font is neither embedded nor installed, so previews substitute \(font.fallbackFamily)."
      }
      warning = text
    } else if font.mayBeCommerciallyLicensed {
      warning =
        "“\(font.familyName)” may be commercially licensed. The app never downloads or bundles paid fonts; install it from your own licensed copy if you need it."
    } else if needsProvisioning {
      warning =
        "“\(font.familyName)” is neither embedded nor installed. Previews will substitute \(font.fallbackFamily)."
    }
    return FontStatus(
      font: font, installed: installed, needsProvisioning: needsProvisioning, warning: warning,
      fallback: font.fallbackFamily)
  }

  public static func statuses(
    for fonts: [PDFDocumentFont], availability: FontAvailability = .system
  ) -> [FontStatus] {
    fonts.map { status(for: $0, availability: availability) }
  }

  /// P43-003: the warning shown before an edit is committed. Nil when the font
  /// resolves; otherwise the substitution consequences are stated.
  public static func editingWarning(
    for font: PDFDocumentFont, availability: FontAvailability = .system
  ) -> String? {
    guard !availability.isInstalled(font.familyName) else { return nil }
    return
      "This text uses “\(font.familyName)”, which is not installed. The document keeps its embedded widths and encoding, so saved metrics stay exact; the on-screen preview will substitute \(font.fallbackFamily) until the font is installed."
  }
}

/// P43-005/P43-008/P43-012: the Google Fonts catalog. The metadata endpoint is
/// the one fonts.google.com itself uses; nothing is fetched until a user
/// action calls it, and only the family the user chose is ever requested.
public struct GoogleFontsFamily: Sendable, Equatable {
  public let name: String
  public let category: String?
  public let isOpenSource: Bool?

  public init(name: String, category: String?, isOpenSource: Bool?) {
    self.name = name
    self.category = category
    self.isOpenSource = isOpenSource
  }
}

public struct GoogleFontsClient: Sendable {
  public var load: @Sendable (URL) async throws -> (Data, URLResponse)

  public init(load: @escaping @Sendable (URL) async throws -> (Data, URLResponse)) {
    self.load = load
  }

  public static let live = GoogleFontsClient { url in
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.setValue("sPDF-Editor/0.1", forHTTPHeaderField: "User-Agent")
    return try await URLSession.shared.data(for: request)
  }
}

public enum GoogleFontsCatalog {
  public static let metadataURL = URL(string: "https://fonts.google.com/metadata/fonts")!
  public static let maxMetadataBytes = 8 * 1_024 * 1_024

  /// P43-005: the full catalog, fetched only when the user asks to browse or
  /// search. Bounded before parsing.
  public static func families(
    client: GoogleFontsClient = .live, limits: GoogleFontsInstaller.Limits = .init()
  ) async throws -> [GoogleFontsFamily] {
    let (data, response) = try await client.load(metadataURL)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw FontProvisioningError.network("The Google Fonts catalog is unavailable.")
    }
    guard data.count <= limits.maxMetadataBytes else {
      throw FontProvisioningError.tooLarge("The Google Fonts catalog exceeded the fetch bound.")
    }
    return try parseFamilies(data)
  }

  static func parseFamilies(_ data: Data) throws -> [GoogleFontsFamily] {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let list = object["familyMetadataList"] as? [[String: Any]]
    else {
      throw FontProvisioningError.malformed("The Google Fonts catalog could not be parsed.")
    }
    return list.compactMap { entry in
      guard let name = entry["family"] as? String else { return nil }
      return GoogleFontsFamily(
        name: name, category: entry["category"] as? String,
        isOpenSource: entry["isOpenSource"] as? Bool)
    }
  }

  /// P43-005: local search over the fetched catalog.
  public static func search(
    _ query: String, in families: [GoogleFontsFamily], limit: Int = 25
  ) -> [GoogleFontsFamily] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return Array(families.prefix(limit)) }
    let exact = families.filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    let prefix = families.filter {
      $0.name.lowercased().hasPrefix(trimmed.lowercased()) && !exact.contains($0)
    }
    let contains = families.filter {
      $0.name.localizedCaseInsensitiveContains(trimmed)
        && !exact.contains($0) && !prefix.contains($0)
    }
    return Array((exact + prefix + contains).prefix(limit))
  }
}

public enum FontProvisioningError: Error, LocalizedError {
  case network(String)
  case tooLarge(String)
  case malformed(String)
  case licenseRequired
  case notFound(String)

  public var errorDescription: String? {
    switch self {
    case .network(let message), .tooLarge(let message), .malformed(let message),
      .notFound(let message):
      return message
    case .licenseRequired:
      return "Fonts are installed only after the license terms are shown and accepted."
    }
  }
}

public struct GoogleFontFile: Sendable, Equatable {
  public let name: String
  public let data: Data
}

public struct GoogleFontPackage: Sendable, Equatable {
  public let family: String
  public let files: [GoogleFontFile]
  public let licenseText: String?
}

/// P43-006/P43-009/P43-010/P43-012: fetch and install Google Fonts families
/// from the official google/fonts repository. Downloads go to memory only;
/// installation copies to the user font directory and registers the fonts.
public enum GoogleFontsInstaller {
  public struct Limits: Sendable, Equatable {
    public var maxMetadataBytes: Int
    public var maxFontBytes: Int
    public var maxFileBytes: Int
    public var maxFiles: Int

    public init(
      maxMetadataBytes: Int = 8 * 1_024 * 1_024, maxFontBytes: Int = 50 * 1_024 * 1_024,
      maxFileBytes: Int = 20 * 1_024 * 1_024, maxFiles: Int = 20
    ) {
      self.maxMetadataBytes = maxMetadataBytes
      self.maxFontBytes = maxFontBytes
      self.maxFileBytes = maxFileBytes
      self.maxFiles = maxFiles
    }
  }

  /// Official repository listing endpoints, tried in order.
  static let licenseDirectories = ["ofl", "apache", "ufl"]

  static func slug(_ family: String) -> String {
    family.lowercased().replacingOccurrences(of: " ", with: "")
  }

  static func listingURL(family: String, directory: String) -> URL {
    URL(
      string:
        "https://api.github.com/repos/google/fonts/contents/\(directory)/\(slug(family))")!
  }

  /// P43-005/P43-010: download the family's font files and license into
  /// memory. Nothing is installed here; failures leave no partial state.
  public static func prepare(
    family: String, client: GoogleFontsClient = .live, limits: Limits = .init()
  ) async throws -> GoogleFontPackage {
    var listing: [[String: Any]]?
    for directory in licenseDirectories {
      let (data, response) = try await client.load(listingURL(family: family, directory: directory))
      guard let http = response as? HTTPURLResponse else { continue }
      if http.statusCode == 404 { continue }
      guard (200...299).contains(http.statusCode) else {
        throw FontProvisioningError.network("The font listing could not be fetched.")
      }
      guard data.count <= limits.maxMetadataBytes else {
        throw FontProvisioningError.tooLarge("The font listing exceeded the fetch bound.")
      }
      listing = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
      break
    }
    guard let entries = listing else {
      throw FontProvisioningError.notFound(
        "“\(family)” was not found in the Google Fonts repository.")
    }

    let licenseName = entries.compactMap { $0["name"] as? String }.first {
      ["OFL.txt", "LICENSE.txt", "UFL.txt", "OFL-1.1.txt"].contains($0)
    }
    var licenseText: String?
    if let licenseName,
      let entry = entries.first(where: { $0["name"] as? String == licenseName }),
      let urlString = entry["download_url"] as? String, let url = URL(string: urlString)
    {
      let (data, _) = try await client.load(url)
      if data.count <= 512 * 1_024 {
        licenseText = String(data: data, encoding: .utf8)
      }
    }

    // Prefer variable fonts (a single file covers weights), then regular
    // styles, then the rest; the count and total size are bounded.
    let fontEntries = entries.compactMap { entry -> (name: String, url: URL, size: Int)? in
      guard let name = entry["name"] as? String,
        name.hasSuffix(".ttf") || name.hasSuffix(".otf"),
        let urlString = entry["download_url"] as? String, let url = URL(string: urlString)
      else { return nil }
      let size = (entry["size"] as? Int) ?? 0
      return (name, url, size)
    }
    let sorted = fontEntries.sorted { left, right in
      func rank(_ name: String) -> Int {
        if name.contains("[") { return 0 }
        if name.lowercased().contains("regular") { return 1 }
        return 2
      }
      return (rank(left.name), left.name) < (rank(right.name), right.name)
    }
    var files: [GoogleFontFile] = []
    var total = 0
    for entry in sorted {
      guard files.count < limits.maxFiles else { break }
      guard entry.size <= limits.maxFileBytes else { continue }
      guard total + entry.size <= limits.maxFontBytes else { break }
      let (data, response) = try await client.load(entry.url)
      if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        throw FontProvisioningError.network("A font file could not be downloaded.")
      }
      guard data.count <= limits.maxFileBytes else {
        throw FontProvisioningError.tooLarge("A font file exceeded the download bound.")
      }
      total += data.count
      files.append(GoogleFontFile(name: entry.name, data: data))
    }
    guard !files.isEmpty else {
      throw FontProvisioningError.notFound("No installable font files were found for “\(family)”.")
    }
    return GoogleFontPackage(family: family, files: files, licenseText: licenseText)
  }

  /// P43-006: the Font Book-compatible per-user location.
  public static func defaultFontsDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Fonts", isDirectory: true)
  }

  /// P43-006/P43-010: copy prepared files into the destination and register
  /// them. Any failure removes everything this call wrote (no partial
  /// installs); the caller must have shown and accepted the license first.
  @discardableResult
  public static func install(
    _ package: GoogleFontPackage, to directory: URL? = nil,
    licenseAccepted: Bool = true
  ) throws -> [URL] {
    guard licenseAccepted else { throw FontProvisioningError.licenseRequired }
    let destination = directory ?? defaultFontsDirectory()
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    var written: [URL] = []
    do {
      for file in package.files {
        let url = destination.appendingPathComponent(file.name)
        try file.data.write(to: url, options: .atomic)
        written.append(url)
      }
    } catch {
      for url in written { try? FileManager.default.removeItem(at: url) }
      throw error
    }
    register(written)
    return written
  }

  /// Best-effort immediate registration; ~/Library/Fonts is picked up by the
  /// system regardless.
  public static func register(_ urls: [URL]) {
    for url in urls {
      var error: Unmanaged<CFError>?
      CTFontManagerRegisterFontsForURL(url as CFURL, .user, &error)
    }
  }
}
