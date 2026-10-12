import Foundation
import PDFCore

/// P43-002/P43-004/P43-011: the fonts a document uses, with embedding and
/// subset facts, a commercial-license heuristic, and concrete substitution
/// fallbacks. The inventory is pure: system availability is checked by the
/// MacServices layer so this stays testable without CoreText.
public struct PDFDocumentFont: Sendable, Equatable {
  public let resource: String
  public let baseName: String
  public let subtype: String
  public let encoding: String?
  public let isEmbedded: Bool
  public let isSubset: Bool
  public let isType0: Bool
  /// P14-023: a Type 3 font whose glyphs are content-stream programs.
  /// Readable; never rewritten by this profile.
  public let isType3: Bool
  public let pageIndices: [Int]

  public init(
    resource: String, baseName: String, subtype: String, encoding: String?, isEmbedded: Bool,
    isSubset: Bool, isType0: Bool, isType3: Bool = false, pageIndices: [Int]
  ) {
    self.resource = resource
    self.baseName = baseName
    self.subtype = subtype
    self.encoding = encoding
    self.isEmbedded = isEmbedded
    self.isSubset = isSubset
    self.isType0 = isType0
    self.isType3 = isType3
    self.pageIndices = pageIndices
  }

  /// The family name without a subset prefix (`ABCDEF+Name` -> `Name`).
  public var familyName: String {
    let name = baseName
    let parts = name.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
    if parts.count == 2, parts[0].count == 6, parts[0].allSatisfy({ $0.isUppercase }) {
      return String(parts[1])
    }
    return name
  }

  /// The standard-14 base fonts are expected to resolve without embedding.
  public var isStandard14: Bool {
    Self.standard14.contains(familyName)
  }

  public static let standard14: Set<String> = [
    "Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique",
    "Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic",
    "Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique",
    "Symbol", "ZapfDingbats",
  ]

  /// P43-004: a curated heuristic, never a claim. Matches common commercial
  /// families and suffixes; anything matched is surfaced as "may be licensed".
  public var mayBeCommerciallyLicensed: Bool {
    Self.commercialFamilies.contains { familyName.localizedCaseInsensitiveContains($0) }
      || ["-Pro", "Pro-", " MT", " LT", " Std", "-Std", "Com"].contains { suffix in
        baseName.contains(suffix)
      }
  }

  static let commercialFamilies: [String] = [
    "Minion", "Myriad", "Frutiger", "Univers", "Garamond Premier", "Sabon", "Bembo",
    "Gill Sans", "Brandon Grotesque", "Proxima Nova", "Gotham", "Calibri", "Cambria",
    "Segoe", "Aptos", "Futura", "DIN ", "Avenir", "Baskerville", "Adobe Caslon",
    "Neue Haas", "Akzidenz", "Eurostile", "Fira Sans", "Museo", "FF Meta", "Dax",
  ]

  /// P43-011: a concrete substitution fallback so previews and warnings are
  /// predictable. Metrics for exports still come from the document.
  public var fallbackFamily: String {
    FontFallback.family(for: familyName)
  }
}

/// P43-011: deterministic fallback mapping by family-name heuristics.
public enum FontFallback {
  public static func family(for name: String) -> String {
    let lowered = name.lowercased()
    if ["mono", "courier", "code", "consol", "menlo"].contains(where: { lowered.contains($0) }) {
      return "Menlo"
    }
    if ["symbol", "dingbat", "zapf", "wingding"].contains(where: { lowered.contains($0) }) {
      return "Apple Symbols"
    }
    if ["serif", "times", "garamond", "minion", "sabon", "bembo", "caslon", "georgia",
        "palatino", "book"]
      .contains(where: { lowered.contains($0) })
    {
      return "Times New Roman"
    }
    return "Helvetica"
  }
}

/// P15-006: one member of the small explicitly licensed fallback-font set.
/// Members are SIL OFL families provisionable through the app's Google Fonts
/// flow (P43); system fonts are never members because they are render-only
/// and must not be embedded. `scripts` documents the intended coverage only;
/// actual glyph coverage is always verified against the installed font at
/// selection time, never trusted from this table.
public struct LicensedFallbackFont: Sendable, Equatable {
  public enum Style: String, Sendable {
    case sans
    case serif
    case mono
  }

  public let family: String
  public let style: Style
  public let license: String
  public let provisionSource: String
  public let scripts: [String]

  public init(
    family: String, style: Style, license: String, provisionSource: String, scripts: [String]
  ) {
    self.family = family
    self.style = style
    self.license = license
    self.provisionSource = provisionSource
    self.scripts = scripts
  }
}

/// P15-006: the small explicitly licensed fallback-font set used when
/// required replacement glyphs are absent and no reusable embedded font
/// covers them. Selection is deterministic and injectable so tests never
/// depend on what is installed; callers verify real glyph coverage before
/// embedding.
public enum LicensedFallbackSet {
  public static let fonts: [LicensedFallbackFont] = [
    LicensedFallbackFont(
      family: "Noto Sans", style: .sans, license: "OFL-1.1",
      provisionSource: "Google Fonts (google/fonts repository, OFL directory)",
      scripts: ["Latin", "Greek", "Cyrillic", "Hebrew", "Arabic"]),
    LicensedFallbackFont(
      family: "Noto Serif", style: .serif, license: "OFL-1.1",
      provisionSource: "Google Fonts (google/fonts repository, OFL directory)",
      scripts: ["Latin", "Greek", "Cyrillic"]),
    LicensedFallbackFont(
      family: "Noto Sans Mono", style: .mono, license: "OFL-1.1",
      provisionSource: "Google Fonts (google/fonts repository, OFL directory)",
      scripts: ["Latin", "Greek", "Cyrillic"]),
  ]

  /// Members in selection order: the preferred style first (listed order),
  /// then the rest (listed order).
  public static func ordered(
    preferring style: LicensedFallbackFont.Style? = nil
  ) -> [LicensedFallbackFont] {
    guard let style else { return fonts }
    return fonts.filter { $0.style == style } + fonts.filter { $0.style != style }
  }

  /// The first member (selection order) whose family is in `installed`
  /// (exact-name match), or nil when no licensed member qualifies — never a
  /// silent substitution with a render-only system font.
  public static func pick(
    preferring style: LicensedFallbackFont.Style? = nil, installed: Set<String>
  ) -> LicensedFallbackFont? {
    ordered(preferring: style).first { installed.contains($0.family) }
  }
}
/// P43-003 support: resolve the font facts of one editable text run so the
/// editing path can warn before a commit.
public enum PDFTextFontLookup {
  public static func font(
    forRunAt index: Int, pageID: PDFObjectID, in graph: PDFGraph
  ) throws -> PDFDocumentFont? {
    let content = try PageContent.load(pageID: pageID, in: graph)
    let runs = try TextRunIndexer.runs(in: content, graph: graph)
    guard index >= 0, index < runs.count,
      case .dictionary(let dictionary)? = graph.objects[runs[index].fontID]
    else { return nil }
    return PDFFontInventory.parse(
      resource: String(decoding: runs[index].fontResource.bytes, as: UTF8.self),
      dictionary: dictionary, graph: graph, pageIndex: 0)
  }
}

public enum PDFFontInventory {
  /// Every font resource used by the given pages, deduplicated by family and
  /// embedding facts, in first-use order.
  public static func fonts(in graph: PDFGraph, pageIDs: [PDFObjectID]) -> [PDFDocumentFont] {
    var seen: [String: Int] = [:]
    var result: [PDFDocumentFont] = []
    for (pageIndex, pageID) in pageIDs.enumerated() {
      guard case .dictionary(let page)? = graph.objects[pageID] else { continue }
      var resources: [PDFName: PDFValue] = [:]
      if case .dictionary(let dictionary)? = page[PDFName("Resources")] {
        resources = dictionary
      } else if case .reference(let id)? = page[PDFName("Resources")],
        case .dictionary(let dictionary)? = graph.objects[id]
      {
        resources = dictionary
      }
      var fonts: [PDFName: PDFValue] = [:]
      switch resources[PDFName("Font")] {
      case .dictionary(let dictionary)?:
        fonts = dictionary
      case .reference(let id)?:
        if case .dictionary(let dictionary)? = graph.objects[id] { fonts = dictionary }
      default:
        break
      }
      for (resource, value) in fonts {
        guard case .dictionary(let dictionary) = resolved(value, in: graph) else { continue }
        guard
          let font = parse(
            resource: String(decoding: resource.bytes, as: UTF8.self), dictionary: dictionary,
            graph: graph, pageIndex: pageIndex)
        else { continue }
        let key = "\(font.baseName)|\(font.subtype)|\(font.isEmbedded)"
        if let index = seen[key] {
          let existing = result[index]
          var pages = existing.pageIndices
          if !pages.contains(pageIndex) { pages.append(pageIndex) }
          result[index] = PDFDocumentFont(
            resource: existing.resource, baseName: existing.baseName, subtype: existing.subtype,
            encoding: existing.encoding, isEmbedded: existing.isEmbedded,
            isSubset: existing.isSubset, isType0: existing.isType0,
            isType3: existing.isType3, pageIndices: pages)
          continue
        }
        seen[key] = result.count
        result.append(font)
      }
    }
    return result
  }

  /// Parse one font dictionary into its document-font facts.
  static func parse(
    resource: String, dictionary: [PDFName: PDFValue], graph: PDFGraph, pageIndex: Int
  ) -> PDFDocumentFont? {
    let baseName = nameString(dictionary[PDFName("BaseFont")]) ?? resource
    let subtype = nameString(dictionary[PDFName("Subtype")]) ?? ""
    let isType0 = subtype == "Type0"
    let isType3 = subtype == "Type3"
    let descriptor = descriptorDictionary(of: dictionary, in: graph)
    let isEmbedded =
      descriptor?[PDFName("FontFile")] != nil
      || descriptor?[PDFName("FontFile2")] != nil
      || descriptor?[PDFName("FontFile3")] != nil
      || (isType0 && descendantDescriptor(of: dictionary, in: graph) != nil)
    return PDFDocumentFont(
      resource: resource, baseName: baseName, subtype: subtype,
      encoding: encodingName(dictionary[PDFName("Encoding")]), isEmbedded: isEmbedded,
      isSubset: isSubsetName(baseName), isType0: isType0, isType3: isType3,
      pageIndices: [pageIndex])
  }

  /// Six uppercase letters followed by `+` marks a subset.
  static func isSubsetName(_ name: String) -> Bool {
    let parts = name.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return false }
    return parts[0].count == 6 && parts[0].allSatisfy { $0.isUppercase }
  }

  private static func resolved(_ value: PDFValue, in graph: PDFGraph) -> PDFValue {
    if case .reference(let id) = value, let object = graph.objects[id] { return object }
    return value
  }

  private static func descriptorDictionary(
    of font: [PDFName: PDFValue], in graph: PDFGraph
  ) -> [PDFName: PDFValue]? {
    switch font[PDFName("FontDescriptor")] {
    case .reference(let id)?:
      if case .dictionary(let descriptor)? = graph.objects[id] { return descriptor }
    case .dictionary(let descriptor)?:
      return descriptor
    default:
      break
    }
    return nil
  }

  private static func descendantDescriptor(
    of font: [PDFName: PDFValue], in graph: PDFGraph
  ) -> [PDFName: PDFValue]? {
    guard case .array(let descendants)? = font[PDFName("DescendantFonts")],
      case .reference(let descendantID)? = descendants.first,
      case .dictionary(let descendant)? = graph.objects[descendantID]
    else { return nil }
    return descriptorDictionary(of: descendant, in: graph)
  }

  private static func nameString(_ value: PDFValue?) -> String? {
    guard case .name(let name)? = value else { return nil }
    return String(decoding: name.bytes, as: UTF8.self)
  }

  private static func encodingName(_ value: PDFValue?) -> String? {
    switch value {
    case .name(let name)?:
      return String(decoding: name.bytes, as: UTF8.self)
    case .dictionary(let dictionary)?:
      if case .name(let name)? = dictionary[PDFName("BaseEncoding")] {
        return String(decoding: name.bytes, as: UTF8.self)
      }
      return dictionary[PDFName("Differences")] != nil ? "Differences" : nil
    default:
      return nil
    }
  }
}
