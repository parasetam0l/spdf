import Foundation
import PDFCore

/// P37-001/P37-002: the version and extension audit. The profile reads PDF 2.0
/// structure but implements no PDF 2.0 feature beyond what the decision 0024
/// records, so extensions are reported as preserved or unknown — never as
/// supported features.
public struct PDFVersionAudit: Sendable, Equatable {
  public struct Extension: Sendable, Equatable {
    public let prefix: String
    public let baseVersion: String?
    public let extensionLevel: Int?
    /// True when the profile preserves the extension dictionary through
    /// rewrites (it always does for unknown catalog keys) — not a feature
    /// implementation claim.
    public let preserved: Bool

    public init(
      prefix: String, baseVersion: String?, extensionLevel: Int?, preserved: Bool
    ) {
      self.prefix = prefix
      self.baseVersion = baseVersion
      self.extensionLevel = extensionLevel
      self.preserved = preserved
    }
  }

  public let headerVersion: String
  public let catalogVersion: String?
  public let extensions: [Extension]
  public let notes: [String]

  public init(
    headerVersion: String, catalogVersion: String?, extensions: [Extension], notes: [String]
  ) {
    self.headerVersion = headerVersion
    self.catalogVersion = catalogVersion
    self.extensions = extensions
    self.notes = notes
  }

  /// The higher of the header and catalog versions (simple numeric compare).
  public var effectiveVersion: String {
    guard let catalogVersion else { return headerVersion }
    return catalogVersion > headerVersion ? catalogVersion : headerVersion
  }

  /// True when the file declares PDF 2.0 anywhere.
  public var declaresPDF20: Bool {
    headerVersion == "2.0" || catalogVersion == "2.0"
  }

  /// P37-004: only extensions this profile actually implements. The current
  /// answer is none, so no blanket support claim is ever made.
  public var implementedExtensionPrefixes: [String] { [] }

  public static func audit(in graph: PDFGraph) -> PDFVersionAudit {
    var notes: [String] = []
    var catalogVersion: String?
    var extensions: [Extension] = []
    if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID]
    {
      if case .name(let name)? = catalog[PDFName("Version")] {
        catalogVersion = String(decoding: name.bytes, as: UTF8.self)
      }
      if case .dictionary(let dictionary)? = catalog[PDFName("Extensions")] {
        for (key, value) in dictionary.sorted(by: {
          String(decoding: $0.key.bytes, as: UTF8.self)
            < String(decoding: $1.key.bytes, as: UTF8.self)
        }) {
          let prefix = String(decoding: key.bytes, as: UTF8.self)
          var baseVersion: String?
          var level: Int?
          if case .dictionary(let entry) = value {
            if case .name(let name)? = entry[PDFName("BaseVersion")] {
              baseVersion = String(decoding: name.bytes, as: UTF8.self)
            }
            if case .integer(let raw)? = entry[PDFName("ExtensionLevel")] {
              level = Int(exactly: raw)
            }
          }
          extensions.append(
            Extension(
              prefix: prefix, baseVersion: baseVersion, extensionLevel: level, preserved: true))
        }
      }
    }
    if graph.version == "2.0" {
      notes.append(
        "The file declares PDF 2.0; this profile reads the structure but implements no PDF 2.0 feature beyond the recorded capability list.")
    }
    for entry in extensions {
      notes.append(
        "Extension \(entry.prefix) (base \(entry.baseVersion ?? "?") level \(entry.extensionLevel.map(String.init) ?? "?")) is preserved on rewrite; its features are not implemented.")
    }
    if catalogVersion != nil, catalogVersion != graph.version {
      notes.append(
        "The catalog /Version (\(catalogVersion ?? "?")) differs from the header (\(graph.version)).")
    }
    return PDFVersionAudit(
      headerVersion: graph.version, catalogVersion: catalogVersion, extensions: extensions,
      notes: notes)
  }

  public func report() -> String {
    var lines = ["PDF version audit — header \(headerVersion), catalog \(catalogVersion ?? "—")"]
    for note in notes { lines.append("  - \(note)") }
    if extensions.isEmpty { lines.append("  No extension dictionaries.") }
    return lines.joined(separator: "\n")
  }
}

/// P37-005/P37-006: the selected archival profile. PDF/A-2b is chosen: it
/// allows transparency (which this profile preserves) while remaining widely
/// validated. No PDF/A identifier is ever written before validation succeeds.
public enum ArchivalProfile: String, Sendable, Equatable, CaseIterable {
  case pdfa2b = "PDF/A-2b"

  public static let selected: ArchivalProfile = .pdfa2b

  public var standard: String { "ISO 19005-2" }

  /// P37-007: forbidden features for the chosen profile.
  public var forbiddenFeatures: [String] {
    ["Encryption", "JavaScript and executable actions", "Embedded files (A-2)",
      "NeedAppearances true", "Movie and Sound annotations"]
  }

  /// P37-007: required metadata and structure.
  public var requiredFeatures: [String] {
    ["XMP metadata with PDF/A identification", "OutputIntent when device colors are used",
      "Embedded fonts for all rendered text", "File identifier in the trailer"]
  }
}

/// P37-007–P37-011: an inventory of the chosen profile's requirements over a
/// document. This is evidence for a staged derivative — never a conformance
/// claim, and it never writes a PDF/A identifier.
public struct ArchivalInventory: Sendable, Equatable {
  public struct Finding: Sendable, Equatable {
    public enum Severity: String, Sendable, Equatable {
      /// Would fail validation for the chosen profile.
      case error
      /// Needs human review or a later validation run.
      case warning
      /// Observed and allowed by the profile.
      case info
    }

    public let rule: String
    public let severity: Severity
    public let detail: String
    public let count: Int

    public init(rule: String, severity: Severity, detail: String, count: Int) {
      self.rule = rule
      self.severity = severity
      self.detail = detail
      self.count = count
    }
  }

  public let profile: ArchivalProfile
  public let findings: [Finding]

  public init(profile: ArchivalProfile, findings: [Finding]) {
    self.profile = profile
    self.findings = findings
  }

  public var errorCount: Int { findings.filter { $0.severity == .error }.count }
  public var warningCount: Int { findings.filter { $0.severity == .warning }.count }
  /// True only when the inventory found no error-level rule violations. This
  /// is not a conformance claim: independent validation still has to pass.
  public var passesInventory: Bool { errorCount == 0 }

  public static func inventory(
    _ graph: PDFGraph, pageIDs: [PDFObjectID], profile: ArchivalProfile = .selected
  ) -> ArchivalInventory {
    var findings: [Finding] = []
    let objects = graph.objects

    // Encryption (ISO 19005-2 §6.1.3).
    if graph.trailer[PDFName("Encrypt")] != nil {
      findings.append(
        Finding(
          rule: "Encryption", severity: .error,
          detail: "The trailer carries /Encrypt; the profile forbids encryption.", count: 1))
    }

    // JavaScript and executable actions (§6.6.2). Actions live in nested
    // dictionaries (/A, /AA), so the scan walks values with a visited set and
    // a node budget.
    var actionCount = 0
    var visited: Set<PDFObjectID> = []
    var budget = 50_000
    func walk(_ value: PDFValue, depth: Int) {
      guard depth <= 3, budget > 0 else { return }
      budget -= 1
      switch value {
      case .dictionary(let dictionary):
        for key in ["AA", "OpenAction", "JavaScript", "JS", "Launch", "Sound", "Movie", "Rendition"]
        where dictionary[PDFName(key)] != nil {
          actionCount += 1
        }
        for (_, nested) in dictionary { walk(nested, depth: depth + 1) }
      case .array(let values):
        for nested in values { walk(nested, depth: depth + 1) }
      case .reference(let id):
        guard !visited.contains(id), let nested = objects[id] else { return }
        visited.insert(id)
        walk(nested, depth: depth + 1)
      default:
        break
      }
    }
    for (_, value) in objects { walk(value, depth: 0) }
    if actionCount > 0 {
      findings.append(
        Finding(
          rule: "Executable actions", severity: .error,
          detail: "JavaScript or executable actions are present.", count: actionCount))
    }

    // Embedded files (forbidden for PDF/A-2; allowed only in A-3).
    var embeddedFiles = 0
    if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = objects[catalogID],
      case .dictionary(let names)? = catalog[PDFName("Names")],
      names[PDFName("EmbeddedFiles")] != nil
    {
      embeddedFiles = 1
    }
    if embeddedFiles > 0 {
      findings.append(
        Finding(
          rule: "Embedded files", severity: .error,
          detail: "Embedded files are not allowed by PDF/A-2 (PDF/A-3 would be required).",
          count: embeddedFiles))
    }

    // NeedAppearances true (§6.1.4).
    var needAppearances = 0
    for (_, value) in objects {
      guard case .dictionary(let dictionary) = value,
        case .dictionary(let form)? = dictionary[PDFName("AcroForm")],
        case .boolean(let flag)? = form[PDFName("NeedAppearances")], flag
      else { continue }
      needAppearances += 1
    }
    if needAppearances > 0 {
      findings.append(
        Finding(
          rule: "NeedAppearances", severity: .error,
          detail: "AcroForm /NeedAppearances is true.", count: needAppearances))
    }

    // Movie and Sound annotations.
    var mediaAnnotations = 0
    for (_, value) in objects {
      guard case .dictionary(let dictionary) = value,
        case .name(let subtype)? = dictionary[PDFName("Subtype")]
      else { continue }
      let name = String(decoding: subtype.bytes, as: UTF8.self)
      if name == "Movie" || name == "Sound" { mediaAnnotations += 1 }
    }
    if mediaAnnotations > 0 {
      findings.append(
        Finding(
          rule: "Media annotations", severity: .error,
          detail: "Movie or Sound annotations are present.", count: mediaAnnotations))
    }

    // XMP metadata with PDF/A identification (required).
    var hasMetadata = false
    if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = objects[catalogID],
      catalog[PDFName("Metadata")] != nil
    {
      hasMetadata = true
    }
    findings.append(
      Finding(
        rule: "XMP metadata", severity: hasMetadata ? .warning : .error,
        detail: hasMetadata
          ? "XMP metadata is present; verify the PDF/A identification (part and conformance) independently."
          : "No XMP metadata stream; PDF/A identification would have to be added and validated.",
        count: hasMetadata ? 1 : 0))

    // OutputIntent when device colors are used (§6.2.2).
    let hasOutputIntent: Bool
    if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = objects[catalogID],
      case .array(let intents)? = catalog[PDFName("OutputIntents")], !intents.isEmpty
    {
      hasOutputIntent = true
    } else {
      hasOutputIntent = false
    }
    if !hasOutputIntent {
      findings.append(
        Finding(
          rule: "OutputIntent", severity: .error,
          detail: "No /OutputIntents while device color spaces are used.", count: 1))
    } else {
      findings.append(
        Finding(
          rule: "OutputIntent", severity: .info,
          detail: "An output intent is present.", count: 1))
    }

    // Font embedding and Unicode mappings (P37-008).
    let fonts = PDFFontInventory.fonts(in: graph, pageIDs: pageIDs)
    let notEmbedded = fonts.filter { !$0.isEmbedded }
    if !notEmbedded.isEmpty {
      findings.append(
        Finding(
          rule: "Font embedding", severity: .error,
          detail: "Not embedded: " + notEmbedded.map(\.baseName).joined(separator: ", "),
          count: notEmbedded.count))
    }
    let type0WithoutEmbedding = fonts.filter { $0.isType0 && !$0.isEmbedded }
    if !type0WithoutEmbedding.isEmpty {
      findings.append(
        Finding(
          rule: "Unicode mappings", severity: .warning,
          detail: "Composite fonts without embedding: "
            + type0WithoutEmbedding.map(\.baseName).joined(separator: ", "),
          count: type0WithoutEmbedding.count))
    }

    // File identifier in the trailer.
    let hasID = graph.trailer[PDFName("ID")] != nil
    findings.append(
      Finding(
        rule: "File identifier", severity: hasID ? .info : .warning,
        detail: hasID ? "The trailer carries /ID." : "The trailer has no /ID entry.",
        count: hasID ? 1 : 0))

    // Transparency is allowed by PDF/A-2 (§6.4) — observed, not a violation.
    let transparency = PDFCompatibilityScan.transparencyCount(in: graph)
    findings.append(
      Finding(
        rule: "Transparency", severity: .info,
        detail: "Transparency is allowed by PDF/A-2; observed \(transparency) soft mask or constant-alpha uses.",
        count: transparency))

    return ArchivalInventory(profile: profile, findings: findings)
  }

  public func report() -> String {
    var lines = [
      "Archival inventory — \(profile.rawValue) (\(profile.standard)); "
        + "\(errorCount) error\(errorCount == 1 ? "" : "s"), \(warningCount) warning\(warningCount == 1 ? "" : "s")"
    ]
    lines.append("This is an inventory, not a conformance claim; no PDF/A identifier is written.")
    for finding in findings {
      lines.append("  [\(finding.severity.rawValue)] \(finding.rule): \(finding.detail)")
    }
    return lines.joined(separator: "\n")
  }
}

/// P37-019–P37-023: a print-preflight inventory. The owner has no press
/// workflow, so no preflight profile is selected and no conformance is
/// claimed; the inventory reports the facts a press workflow would need.
public struct PrintPreflightInventory: Sendable, Equatable {
  public struct PageBoxes: Sendable, Equatable {
    public let pageIndex: Int
    public let mediaBox: [Double]
    public let cropBox: [Double]?
    public let trimBox: [Double]?
    public let bleedBox: [Double]?
    public let artBox: [Double]?

    public var hasBleed: Bool { bleedBox != nil }
  }

  public struct ImageResolution: Sendable, Equatable {
    public let pageIndex: Int
    public let name: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let placementWidth: Double
    public let placementHeight: Double
    /// Effective resolution at the placement size (pixels per inch).
    public var dpiX: Double { placementWidth > 0 ? Double(pixelWidth) / (placementWidth / 72) : 0 }
    public var dpiY: Double { placementHeight > 0 ? Double(pixelHeight) / (placementHeight / 72) : 0 }
  }

  public let pages: [PageBoxes]
  public let fontsEmbedded: Int
  public let fontsNotEmbedded: Int
  public let images: [ImageResolution]
  public let lowResolutionImages: Int
  public let colorSpaceCounts: [String: Int]
  public let spotColorSpaces: Int
  public let iccProfiles: Int
  public let hasOutputIntent: Bool
  public let transparencyUses: Int
  public let overprintUses: Int

  /// P37-019: the owner has no press workflow, so no profile is selected.
  public static let profileSelected = false
  /// Below this effective resolution an image is flagged for print review.
  public static let lowResolutionDPI = 150.0

  public static func inventory(_ graph: PDFGraph, pageIDs: [PDFObjectID]) -> PrintPreflightInventory {
    var pages: [PageBoxes] = []
    for (index, pageID) in pageIDs.enumerated() {
      guard case .dictionary(let page)? = graph.objects[pageID] else { continue }
      func box(_ key: String) -> [Double]? {
        guard case .array(let values)? = page[PDFName(key)] else { return nil }
        let numbers = values.compactMap { value -> Double? in
          switch value {
          case .integer(let number): return Double(number)
          case .real(let number): return number
          default: return nil
          }
        }
        return numbers.count == 4 ? numbers : nil
      }
      pages.append(
        PageBoxes(
          pageIndex: index, mediaBox: box("MediaBox") ?? [0, 0, 612, 792],
          cropBox: box("CropBox"), trimBox: box("TrimBox"), bleedBox: box("BleedBox"),
          artBox: box("ArtBox")))
    }
    let fonts = PDFFontInventory.fonts(in: graph, pageIDs: pageIDs)
    let images = (try? PDFImageInventory.images(in: graph, pageIDs: pageIDs)) ?? []
    let resolutions = images.map { image in
      ImageResolution(
        pageIndex: image.pageIndex, name: image.name, pixelWidth: image.width,
        pixelHeight: image.height,
        placementWidth: max(image.bounds.count == 4 ? image.bounds[2] - image.bounds[0] : 0, 0),
        placementHeight: max(image.bounds.count == 4 ? image.bounds[3] - image.bounds[1] : 0, 0))
    }
    var colorSpaces: [String: Int] = [:]
    var spotColors = 0
    var icc = 0
    for image in images {
      colorSpaces[image.colorSpace, default: 0] += 1
      if image.colorSpace.contains("Separation") || image.colorSpace.contains("DeviceN") {
        spotColors += 1
      }
      if image.colorSpace.contains("ICCBased") { icc += 1 }
    }
    let scan = PDFCompatibilityScan.scan(in: graph)
    let hasOutputIntent: Bool
    if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID],
      case .array(let intents)? = catalog[PDFName("OutputIntents")], !intents.isEmpty
    {
      hasOutputIntent = true
    } else {
      hasOutputIntent = false
    }
    return PrintPreflightInventory(
      pages: pages, fontsEmbedded: fonts.filter(\.isEmbedded).count,
      fontsNotEmbedded: fonts.filter { !$0.isEmbedded }.count, images: resolutions,
      lowResolutionImages: resolutions.filter { $0.dpiX < lowResolutionDPI || $0.dpiY < lowResolutionDPI }
        .count,
      colorSpaceCounts: colorSpaces, spotColorSpaces: spotColors, iccProfiles: icc,
      hasOutputIntent: hasOutputIntent, transparencyUses: scan.transparency,
      overprintUses: scan.overprint)
  }

  public func report() -> String {
    var lines = ["Print preflight inventory — \(pages.count) page\(pages.count == 1 ? "" : "s")"]
    if !Self.profileSelected {
      lines.append("No preflight profile is selected (no press workflow); this is an inventory, not a claim.")
    }
    for page in pages {
      var boxText = "MediaBox \(format(page.mediaBox))"
      if let crop = page.cropBox { boxText += ", CropBox \(format(crop))" }
      if let trim = page.trimBox { boxText += ", TrimBox \(format(trim))" }
      if let bleed = page.bleedBox { boxText += ", BleedBox \(format(bleed))" }
      lines.append("  Page \(page.pageIndex + 1): \(boxText)")
    }
    lines.append(
      "  Fonts: \(fontsEmbedded) embedded, \(fontsNotEmbedded) not embedded.")
    lines.append(
      "  Images: \(images.count), \(lowResolutionImages) below \(Int(Self.lowResolutionDPI)) dpi at placement size.")
    if !colorSpaceCounts.isEmpty {
      let summary = colorSpaceCounts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }
      lines.append("  Color spaces: " + summary.joined(separator: ", "))
    }
    lines.append(
      "  Spot colors: \(spotColorSpaces); ICC profiles: \(iccProfiles); output intent: \(hasOutputIntent ? "present" : "missing").")
    lines.append(
      "  Transparency uses: \(transparencyUses); overprint uses: \(overprintUses).")
    return lines.joined(separator: "\n")
  }

  private func format(_ box: [Double]) -> String {
    box.map { String(format: "%.0f", $0) }.joined(separator: "×")
  }
}

/// Shared dictionary scan for transparency and overprint evidence.
enum PDFCompatibilityScan {
  struct Result: Sendable, Equatable {
    let transparency: Int
    let overprint: Int
  }

  static func scan(in graph: PDFGraph) -> Result {
    var transparency = 0
    var overprint = 0
    func resolved(_ value: PDFValue?) -> PDFValue? {
      guard let value else { return nil }
      if case .reference(let id) = value { return graph.objects[id] }
      return value
    }
    func inspect(resources: [PDFName: PDFValue]) {
      guard case .dictionary(let graphics)? = resolved(resources[PDFName("ExtGState")]) else {
        return
      }
      for (_, state) in graphics {
        guard case .dictionary(let entry)? = resolved(state) else { continue }
        var transparent = entry[PDFName("SMask")] != nil
        for key in ["CA", "ca"] {
          if case .real(let alpha)? = entry[PDFName(key)], alpha < 1 { transparent = true }
          if case .integer(let alpha)? = entry[PDFName(key)], alpha < 1 { transparent = true }
        }
        if transparent { transparency += 1 }
        for key in ["OP", "op"] {
          if case .boolean(let flag)? = entry[PDFName(key)], flag { overprint += 1 }
        }
      }
    }
    for (_, value) in graph.objects {
      guard case .dictionary(let dictionary) = value else { continue }
      // Page and form dictionaries carry /Resources; resources dictionaries
      // themselves carry /ExtGState.
      if case .dictionary(let resources)? = resolved(dictionary[PDFName("Resources")]) {
        inspect(resources: resources)
      }
      inspect(resources: dictionary)
    }
    return Result(transparency: transparency, overprint: overprint)
  }

  static func transparencyCount(in graph: PDFGraph) -> Int {
    scan(in: graph).transparency
  }
}
