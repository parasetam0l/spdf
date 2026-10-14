import CryptoKit
import Foundation

/// Release tooling for sPDF Editor: appcast generation/validation, update
/// signature verification, notary result handling, and release manifests.
/// Workflow YAML and small shell scripts orchestrate; the custom logic that
/// produces or validates release metadata lives here (P42-009).
public enum ReleaseToolsError: Error, CustomStringConvertible {
  case invalid(String)

  public var description: String {
    switch self {
    case .invalid(let message): return message
    }
  }
}

// MARK: - Update signatures

public enum UpdateSignature {
  /// Verify a Sparkle EdDSA signature against the packaged app's public key.
  public static func verify(
    publicKeyBase64: String, signatureBase64: String, fileURL: URL
  ) throws -> Bool {
    guard let keyData = Data(base64Encoded: publicKeyBase64),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    else {
      throw ReleaseToolsError.invalid("The public key is not a base64 Ed25519 key")
    }
    guard let signature = Data(base64Encoded: signatureBase64) else {
      throw ReleaseToolsError.invalid("The signature is not base64")
    }
    let file = try Data(contentsOf: fileURL, options: .alwaysMapped)
    return key.isValidSignature(signature, for: file)
  }
}

// MARK: - Release dates

public enum ReleaseDate {
  /// GitHub drafts have a null publishedAt. Use their creation date while
  /// preparing the feed, and prefer the publication date once published.
  public static func iso8601(from data: Data) throws -> String {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ReleaseToolsError.invalid("Release metadata is not a JSON object")
    }
    let value: Any?
    if let published = object["publishedAt"], !(published is NSNull) {
      value = published
    } else {
      value = object["createdAt"]
    }
    guard let date = value as? String, ISO8601DateFormatter().date(from: date) != nil else {
      throw ReleaseToolsError.invalid("The release needs a valid publication or draft creation date")
    }
    return date
  }
}

// MARK: - Appcast

public struct AppcastItem: Sendable {
  public var title: String
  public var published: Date
  public var buildVersion: String
  public var shortVersion: String
  public var minimumSystemVersion: String
  public var releaseNotesHTML: String
  public var releaseNotesLink: String
  public var assetURL: String
  public var assetLength: Int
  public var edSignature: String

  public init(
    title: String, published: Date, buildVersion: String, shortVersion: String,
    minimumSystemVersion: String, releaseNotesHTML: String, releaseNotesLink: String,
    assetURL: String, assetLength: Int, edSignature: String
  ) {
    self.title = title
    self.published = published
    self.buildVersion = buildVersion
    self.shortVersion = shortVersion
    self.minimumSystemVersion = minimumSystemVersion
    self.releaseNotesHTML = releaseNotesHTML
    self.releaseNotesLink = releaseNotesLink
    self.assetURL = assetURL
    self.assetLength = assetLength
    self.edSignature = edSignature
  }
}

public enum Appcast {
  public static func xml(feedTitle: String, feedLink: String, item: AppcastItem) -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.timeZone = TimeZone(identifier: "GMT")
    dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    let notes = item.releaseNotesHTML.replacingOccurrences(
      of: "]]>", with: "]]]]><![CDATA[>")
    return """
      <?xml version="1.0" encoding="utf-8"?>
      <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
        <channel>
          <title>\(escape(feedTitle))</title>
          <link>\(escape(feedLink))</link>
          <item>
            <title>\(escape(item.title))</title>
            <pubDate>\(dateFormatter.string(from: item.published))</pubDate>
            <sparkle:version>\(escape(item.buildVersion))</sparkle:version>
            <sparkle:shortVersionString>\(escape(item.shortVersion))</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>\(escape(item.minimumSystemVersion))</sparkle:minimumSystemVersion>
            <sparkle:fullReleaseNotesLink>\(escape(item.releaseNotesLink))</sparkle:fullReleaseNotesLink>
            <description><![CDATA[\(notes)]]></description>
            <enclosure url="\(escape(item.assetURL))" length="\(item.assetLength)" type="application/octet-stream" sparkle:edSignature="\(escape(item.edSignature))"/>
          </item>
        </channel>
      </rss>

      """
  }

  public static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }
}

public struct AppcastEntry: Sendable {
  public var buildVersion: String?
  public var shortVersion: String?
  public var minimumSystemVersion: String?
  public var enclosureURL: String?
  public var enclosureLength: Int?
  public var edSignature: String?
}

public enum AppcastValidator {
  /// Parse and structurally validate an appcast. When an asset path and the
  /// packaged public key are provided, the length and EdDSA signature must
  /// match the file as well.
  public static func validate(
    data: Data, assetURL: URL? = nil, publicKeyBase64: String? = nil
  ) throws -> [AppcastEntry] {
    let delegate = ParserDelegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse(), delegate.sawChannel else {
      throw ReleaseToolsError.invalid("The appcast is not well-formed RSS")
    }
    guard !delegate.entries.isEmpty else {
      throw ReleaseToolsError.invalid("The appcast has no items")
    }
    for entry in delegate.entries {
      guard let build = entry.buildVersion, !build.isEmpty else {
        throw ReleaseToolsError.invalid("An item is missing sparkle:version")
      }
      guard let short = entry.shortVersion, !short.isEmpty else {
        throw ReleaseToolsError.invalid("An item is missing sparkle:shortVersionString")
      }
      guard let minimum = entry.minimumSystemVersion, !minimum.isEmpty else {
        throw ReleaseToolsError.invalid("An item is missing sparkle:minimumSystemVersion")
      }
      guard let url = entry.enclosureURL, url.hasPrefix("https://") else {
        throw ReleaseToolsError.invalid("An item's enclosure URL is not HTTPS")
      }
      guard let length = entry.enclosureLength, length > 0 else {
        throw ReleaseToolsError.invalid("An item's enclosure length is missing or invalid")
      }
      guard let signature = entry.edSignature,
        let signatureData = Data(base64Encoded: signature), signatureData.count == 64
      else {
        throw ReleaseToolsError.invalid("An item's EdDSA signature is missing or invalid")
      }
      if let assetURL {
        let values = try assetURL.resourceValues(forKeys: [.fileSizeKey])
        guard values.fileSize == length else {
          throw ReleaseToolsError.invalid("The enclosure length does not match the asset")
        }
        if let publicKeyBase64 {
          guard try UpdateSignature.verify(
            publicKeyBase64: publicKeyBase64, signatureBase64: signature, fileURL: assetURL)
          else {
            throw ReleaseToolsError.invalid("The signature does not match the asset")
          }
        }
      }
    }
    return delegate.entries
  }

  private final class ParserDelegate: NSObject, XMLParserDelegate {
    var entries: [AppcastEntry] = []
    var sawChannel = false
    private var current: AppcastEntry?
    private var text = ""

    func parser(
      _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
      qualifiedName qName: String?, attributes: [String: String]
    ) {
      if elementName == "channel" { sawChannel = true }
      if elementName == "item" { current = AppcastEntry() }
      if elementName == "enclosure" {
        current?.enclosureURL = attributes["url"]
        current?.enclosureLength = attributes["length"].flatMap(Int.init)
        current?.edSignature = attributes["sparkle:edSignature"]
      }
      text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
      text += string
    }

    func parser(
      _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
      qualifiedName qName: String?
    ) {
      switch elementName {
      case "item":
        if let current { entries.append(current) }
        current = nil
      case "sparkle:version":
        current?.buildVersion = text.trimmingCharacters(in: .whitespacesAndNewlines)
      case "sparkle:shortVersionString":
        current?.shortVersion = text.trimmingCharacters(in: .whitespacesAndNewlines)
      case "sparkle:minimumSystemVersion":
        current?.minimumSystemVersion = text.trimmingCharacters(in: .whitespacesAndNewlines)
      default:
        break
      }
      text = ""
    }
  }
}

// MARK: - Notary results

public enum NotaryResult {
  public struct Value: Sendable {
    public let status: String
    public let submissionID: String
  }

  public static func parse(_ data: Data) throws -> Value {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ReleaseToolsError.invalid("Notary result is not a JSON object")
    }
    let status = object["status"] as? String ?? ""
    let id = object["id"] as? String ?? ""
    return Value(status: status, submissionID: id)
  }
}

// MARK: - Release manifests

/// P03-023: one private-corpus entry. The manifest lives outside source
/// control (Work/Corpus/manifest.json); only the schema and validation are
/// committed. Paths stay relative to the corpus root so manifests never leak
/// filesystem layout, and every entry names producer/version/features for
/// the measurement matrix.
public struct CorpusEntry: Codable, Sendable, Equatable {
  public var id: String
  public var path: String
  public var producer: String
  public var producerVersion: String
  public var features: [String]
  public var pages: Int
  public var sha256: String?
  public var notes: String?

  public init(
    id: String, path: String, producer: String, producerVersion: String,
    features: [String] = [], pages: Int = 0, sha256: String? = nil,
    notes: String? = nil
  ) {
    self.id = id
    self.path = path
    self.producer = producer
    self.producerVersion = producerVersion
    self.features = features
    self.pages = pages
    self.sha256 = sha256
    self.notes = notes
  }
}

public enum CorpusManifestError: Error, CustomStringConvertible {
  case unreadable(String)
  case invalid(String)

  public var description: String {
    switch self {
    case .unreadable(let reason): return "Corpus manifest unreadable: \(reason)"
    case .invalid(let reason): return "Corpus manifest invalid: \(reason)"
    }
  }
}

public enum CorpusManifest {
  public struct Manifest: Codable, Sendable, Equatable {
    public var version: Int
    public var documents: [CorpusEntry]

    public init(version: Int, documents: [CorpusEntry]) {
      self.version = version
      self.documents = documents
    }
  }

  /// Parse and validate a manifest: version 1, unique non-empty ids, paths
  /// relative without parent escapes, non-negative page counts, and
  /// 64-hex-digit hashes when present.
  public static func load(data: Data) throws -> Manifest {
    let manifest: Manifest
    do {
      manifest = try JSONDecoder().decode(Manifest.self, from: data)
    } catch {
      throw CorpusManifestError.unreadable(error.localizedDescription)
    }
    guard manifest.version == 1 else {
      throw CorpusManifestError.invalid("unsupported version \(manifest.version)")
    }
    var ids = Set<String>()
    for entry in manifest.documents {
      guard !entry.id.isEmpty, ids.insert(entry.id).inserted else {
        throw CorpusManifestError.invalid("duplicate or empty id \(entry.id)")
      }
      guard !entry.path.isEmpty, !entry.path.hasPrefix("/"),
        !entry.path.split(separator: "/").contains("..")
      else {
        throw CorpusManifestError.invalid("path escapes the corpus root (\(entry.id))")
      }
      guard entry.pages >= 0 else {
        throw CorpusManifestError.invalid("negative page count (\(entry.id))")
      }
      if let sha256 = entry.sha256 {
        let hex = sha256.count == 64
          && sha256.allSatisfy { $0.isHexDigit }
        guard hex else {
          throw CorpusManifestError.invalid("malformed sha256 (\(entry.id))")
        }
      }
    }
    return manifest
  }

  public static func sample() -> Manifest {
    Manifest(
      version: 1,
      documents: [
        CorpusEntry(
          id: "synthetic-acme-statement", path: "acme/statement.pdf",
          producer: "Acme Writer", producerVersion: "3.1",
          features: ["tagged", "forms"], pages: 4,
          sha256: String(repeating: "0", count: 63) + "1",
          notes: "Synthetic example only; not a real document."),
      ])
  }
}

// MARK: - Private corpus matrix (P38-025 preparation; P03-023 schema)

/// Groups a validated manifest by producer/version/feature combinations so
/// coverage gaps are explicit. Operates on in-memory entries only (synthetic
/// or owner-supplied); performs no filesystem access and never logs document
/// content. Empty producer/version/feature values are reported under
/// explicit placeholder keys so gaps are visible instead of silently dropped.
public struct CorpusMatrix: Sendable, Equatable {
  public var totalDocuments: Int
  public var totalPages: Int
  public var byProducer: [String: Int]
  public var byProducerVersion: [String: Int]
  public var byFeature: [String: Int]
  public var byCombination: [String: Int]

  public init(
    totalDocuments: Int, totalPages: Int, byProducer: [String: Int],
    byProducerVersion: [String: Int], byFeature: [String: Int],
    byCombination: [String: Int]
  ) {
    self.totalDocuments = totalDocuments
    self.totalPages = totalPages
    self.byProducer = byProducer
    self.byProducerVersion = byProducerVersion
    self.byFeature = byFeature
    self.byCombination = byCombination
  }

  public static let unspecifiedProducer = "<unspecified-producer>"
  public static let unspecifiedVersion = "<unspecified-version>"
  public static let noFeature = "<no-feature>"

  public static func producerVersionKey(producer: String, version: String) -> String {
    "\(producer) @ \(version)"
  }

  public static func combinationKey(producer: String, version: String, feature: String)
    -> String
  {
    "\(producer) @ \(version) + \(feature)"
  }

  static func normalizedProducer(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? unspecifiedProducer : trimmed
  }

  static func normalizedVersion(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? unspecifiedVersion : trimmed
  }

  static func normalizedFeatures(_ raw: [String]) -> [String] {
    let cleaned = raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return Array(Set(cleaned)).sorted()
  }

  /// Build matrix counts from an already-validated manifest.
  public static func build(from manifest: CorpusManifest.Manifest) -> CorpusMatrix {
    var byProducer: [String: Int] = [:]
    var byProducerVersion: [String: Int] = [:]
    var byFeature: [String: Int] = [:]
    var byCombination: [String: Int] = [:]
    var totalPages = 0
    for entry in manifest.documents {
      let producer = normalizedProducer(entry.producer)
      let version = normalizedVersion(entry.producerVersion)
      let features = normalizedFeatures(entry.features)
      totalPages += max(0, entry.pages)
      byProducer[producer, default: 0] += 1
      byProducerVersion[producerVersionKey(producer: producer, version: version), default: 0] += 1
      if features.isEmpty {
        byFeature[noFeature, default: 0] += 1
        byCombination[
          combinationKey(producer: producer, version: version, feature: noFeature),
          default: 0] += 1
      } else {
        for feature in features {
          byFeature[feature, default: 0] += 1
          byCombination[
            combinationKey(producer: producer, version: version, feature: feature),
            default: 0] += 1
        }
      }
    }
    return CorpusMatrix(
      totalDocuments: manifest.documents.count,
      totalPages: totalPages,
      byProducer: byProducer,
      byProducerVersion: byProducerVersion,
      byFeature: byFeature,
      byCombination: byCombination)
  }

  /// Deterministic human-readable summary with sorted keys.
  public func report() -> String {
    func lines(_ title: String, _ counts: [String: Int]) -> [String] {
      var out = ["\(title) (\(counts.count)):"]
      for key in counts.keys.sorted() {
        out.append("  \(key): \(counts[key] ?? 0)")
      }
      return out
    }
    var out = [
      "documents: \(totalDocuments)",
      "pages: \(totalPages)",
    ]
    out += lines("producers", byProducer)
    out += lines("producer-versions", byProducerVersion)
    out += lines("features", byFeature)
    out += lines("combinations", byCombination)
    return out.joined(separator: "\n")
  }
}

public struct ReleaseManifest: Codable, Sendable {
  public var version: String
  public var build: String
  public var minimumSystem: String
  public var bundleIdentifier: String
  public var publicKey: String
  public var assetName: String
  public var assetURL: String
  public var assetLength: Int
  public var assetSHA256: String
  public var edSignature: String
  public var createdAt: String
}

public enum ReleaseManifestBuilder {
  public static func make(
    appURL: URL, assetURL: URL, assetRemoteURL: String, signature: String
  ) throws -> ReleaseManifest {
    let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
    let infoData = try Data(contentsOf: infoURL)
    guard let info = try PropertyListSerialization.propertyList(
      from: infoData, format: nil) as? [String: Any]
    else {
      throw ReleaseToolsError.invalid("The app's Info.plist is not a dictionary")
    }
    let asset = try Data(contentsOf: assetURL, options: .alwaysMapped)
    let digest = SHA256.hash(data: asset).map { String(format: "%02x", $0) }.joined()
    let formatter = ISO8601DateFormatter()
    return ReleaseManifest(
      version: info["CFBundleShortVersionString"] as? String ?? "",
      build: info["CFBundleVersion"] as? String ?? "",
      minimumSystem: info["LSMinimumSystemVersion"] as? String ?? "",
      bundleIdentifier: info["CFBundleIdentifier"] as? String ?? "",
      publicKey: info["SUPublicEDKey"] as? String ?? "",
      assetName: assetURL.lastPathComponent,
      assetURL: assetRemoteURL,
      assetLength: asset.count,
      assetSHA256: digest,
      edSignature: signature,
      createdAt: formatter.string(from: Date()))
  }

  public static func json(_ manifest: ReleaseManifest) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(manifest)
  }
}
