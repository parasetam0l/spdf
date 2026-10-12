import Foundation
import PDFCore

/// P08-003–P08-008: one page's resolved attributes with inheritance applied
/// from its ancestors, a stable session identity, and its content/resources.
public struct PDFPageAttributes: Sendable, Equatable {
  /// Stable within a session: page-tree object number, generation, and index.
  public let identity: String
  public let pageIndex: Int
  public let pageObjectID: PDFObjectID
  public let mediaBox: [Double]
  public let cropBox: [Double]
  public let trimBox: [Double]?
  public let bleedBox: [Double]?
  public let artBox: [Double]?
  /// Normalized to 0/90/180/270.
  public let rotation: Int
  public let userUnit: Double
  public let contentStreamIDs: [PDFObjectID]
  public let hasInheritedResources: Bool

  public var displayBox: [Double] { cropBox }
}

/// P08-007: the resource categories one page uses.
public struct PDFPageResourceInventory: Sendable, Equatable {
  public let pageIndex: Int
  public let fonts: [String]
  public let images: [String]
  public let forms: [String]
  public let patterns: [String]
  public let graphicsStates: [String]
  public let colorSpaces: [String]
  public let shadings: [String]
  public let properties: [String]

  public var isEmpty: Bool {
    fonts.isEmpty && images.isEmpty && forms.isEmpty && patterns.isEmpty
      && graphicsStates.isEmpty && colorSpaces.isEmpty && shadings.isEmpty && properties.isEmpty
  }
}

/// P08-010: page labels from the `/PageLabels` number tree.
public struct PDFPageLabelRange: Sendable, Equatable {
  public enum Style: String, Sendable, Equatable {
    case decimal
    case upperRoman
    case lowerRoman
    case upperAlpha
    case lowerAlpha
    case none
  }

  public let startPageIndex: Int
  public let style: Style
  public let prefix: String
  public let startValue: Int

  public func label(forPageIndex index: Int) -> String? {
    guard index >= startPageIndex else { return nil }
    let number = startValue + (index - startPageIndex)
    let body: String
    switch style {
    case .none: body = ""
    case .decimal: body = String(number)
    case .upperRoman: body = PDFPageLabels.roman(number, upper: true)
    case .lowerRoman: body = PDFPageLabels.roman(number, upper: false)
    case .upperAlpha: body = PDFPageLabels.alpha(number, upper: true)
    case .lowerAlpha: body = PDFPageLabels.alpha(number, upper: false)
    }
    return prefix + body
  }
}

public enum PDFPageLabels {
  public static func ranges(in graph: PDFGraph) -> [PDFPageLabelRange] {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID],
      let value = catalog[PDFName("PageLabels")]
    else { return [] }
    var result: [PDFPageLabelRange] = []
    collect(value, in: graph, into: &result, depth: 0)
    return result.sorted { $0.startPageIndex < $1.startPageIndex }
  }

  /// The label for a page index, falling back to the physical number.
  public static func label(forPageIndex index: Int, in graph: PDFGraph) -> String {
    let ranges = ranges(in: graph)
    for range in ranges.reversed() where index >= range.startPageIndex {
      if let label = range.label(forPageIndex: index) { return label }
    }
    return String(index + 1)
  }

  static func collect(
    _ value: PDFValue, in graph: PDFGraph, into result: inout [PDFPageLabelRange], depth: Int
  ) {
    guard depth <= 32 else { return }
    func resolved(_ value: PDFValue?) -> PDFValue? {
      guard let value else { return nil }
      if case .reference(let id) = value { return graph.objects[id] }
      return value
    }
    guard case .dictionary(let node)? = resolved(value) else { return }
    if case .array(let numbers)? = node[PDFName("Nums")] {
      var index = 0
      while index + 1 < numbers.count {
        if case .integer(let key) = numbers[index],
          case .dictionary(let label) = resolved(numbers[index + 1]) ?? .null
        {
          result.append(
            PDFPageLabelRange(
              startPageIndex: Int(exactly: key) ?? 0,
              style: style(label[PDFName("S")]),
              prefix: string(label[PDFName("P")]) ?? "",
              startValue: (label[PDFName("St")].flatMap { value -> Int? in
                if case .integer(let number) = value { return Int(exactly: number) }
                return nil
              }) ?? 1))
        }
        index += 2
      }
    }
    if case .array(let kids)? = node[PDFName("Kids")] {
      for kid in kids { collect(kid, in: graph, into: &result, depth: depth + 1) }
    }
  }

  static func style(_ value: PDFValue?) -> PDFPageLabelRange.Style {
    guard case .name(let name)? = value else { return .decimal }
    switch String(decoding: name.bytes, as: UTF8.self) {
    case "r": return .lowerRoman
    case "R": return .upperRoman
    case "a": return .lowerAlpha
    case "A": return .upperAlpha
    case "": return .none
    default: return .decimal
    }
  }

  static func string(_ value: PDFValue?) -> String? {
    guard case .string(let data)? = value else { return nil }
    return AnnotationText.decode(data)
  }

  static func roman(_ number: Int, upper: Bool) -> String {
    guard number > 0, number < 4_000 else { return String(number) }
    let table: [(Int, String)] = [
      (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
    ]
    var remaining = number
    var result = ""
    for (value, symbol) in table {
      while remaining >= value {
        result += symbol
        remaining -= value
      }
    }
    return upper ? result : result.lowercased()
  }

  static func alpha(_ number: Int, upper: Bool) -> String {
    guard number > 0 else { return String(number) }
    var remaining = number
    var result = ""
    while remaining > 0 {
      let index = (remaining - 1) % 26
      result = String(UnicodeScalar(UInt8(65 + index))) + result
      remaining = (remaining - 1) / 26
    }
    return upper ? result : result.lowercased()
  }
}

/// P08-014: document-level metadata.
public struct PDFDocumentMetadata: Sendable, Equatable {
  public let title: String?
  public let author: String?
  public let subject: String?
  public let keywords: String?
  public let creator: String?
  public let producer: String?
  public let creationDate: String?
  public let modificationDate: String?
  public let hasFileIdentifier: Bool
  public let hasXMPMetadata: Bool
  public let language: String?

  public var isEmpty: Bool {
    title == nil && author == nil && subject == nil && keywords == nil && creator == nil
      && producer == nil && creationDate == nil && modificationDate == nil && language == nil
  }
}

/// P08-016: optional-content groups and configurations.
public struct PDFOptionalContentInventory: Sendable, Equatable {
  public struct Group: Sendable, Equatable {
    public let name: String?
    public let isVisibleByDefault: Bool
  }

  public let groups: [Group]
  public let configurationNames: [String]
  public let hasOrder: Bool
}

/// P08-018: encryption, signatures, and modification permissions.
public struct PDFSecurityInventory: Sendable, Equatable {
  public let isEncrypted: Bool
  public let encryptionDescription: String?
  public let signatureCount: Int
  public let allowsModification: Bool
  public let allowsAnnotations: Bool
  public let allowsFormFill: Bool
  public let allowsExtraction: Bool
}

/// P08-020: active or interactive content that changes behavior.
public struct PDFActiveContentInventory: Sendable, Equatable {
  public let hasXFA: Bool
  public let hasPortfolio: Bool
  public let hasRichMedia: Bool
  public let has3D: Bool
  public let hasJavaScript: Bool
  public let hasEmbeddedFiles: Bool
  public let hasLaunchActions: Bool

  public var isActive: Bool {
    hasXFA || hasPortfolio || hasRichMedia || has3D || hasJavaScript || hasLaunchActions
  }

  public var summary: [String] {
    var items: [String] = []
    if hasXFA { items.append("XFA form") }
    if hasPortfolio { items.append("portfolio") }
    if hasRichMedia { items.append("rich media") }
    if has3D { items.append("3D content") }
    if hasJavaScript { items.append("JavaScript") }
    if hasEmbeddedFiles { items.append("embedded files") }
    if hasLaunchActions { items.append("launch actions") }
    return items
  }
}

/// P08-022/P08-023: an operation-specific capability assessment built from
/// document-level facts first (no page scanning) and page facts on demand.
public struct PDFCapabilityAssessment: Sendable, Equatable {
  public let canView: Bool
  public let canInspect: Bool
  public let canEditContent: Bool
  public let canWrite: Bool
  public let reasons: [String]
  public let activeContent: PDFActiveContentInventory
  public let security: PDFSecurityInventory

  public var summary: String {
    var parts = [
      "view: \(canView ? "yes" : "no")", "inspect: \(canInspect ? "yes" : "no")",
      "edit: \(canEditContent ? "yes" : "no")", "write: \(canWrite ? "yes" : "no")",
    ]
    if !reasons.isEmpty { parts.append("reasons: " + reasons.joined(separator: "; ")) }
    return parts.joined(separator: ", ")
  }
}

public enum PDFDocumentInventory {
  /// P08-023: document-level facts that never enumerate pages.
  public static func documentFacts(
    in graph: PDFGraph, pageCount: Int, limits: PDFLimits = PDFLimits()
  ) -> (
    metadata: PDFDocumentMetadata, optionalContent: PDFOptionalContentInventory,
    security: PDFSecurityInventory, activeContent: PDFActiveContentInventory
  ) {
    (
      metadata: metadata(in: graph),
      optionalContent: optionalContent(in: graph),
      security: security(in: graph, pageCount: pageCount),
      activeContent: activeContent(in: graph)
    )
  }

  /// P08-003–P08-008: resolved attributes for the given pages.
  public static func pageAttributes(
    pageIDs: [PDFObjectID], in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) -> [PDFPageAttributes] {
    var attributes: [PDFPageAttributes] = []
    for (index, pageID) in pageIDs.enumerated() {
      guard case .dictionary(let page)? = graph.objects[pageID] else { continue }
      let chain = ancestorChain(of: pageID, in: graph, depth: 0)
      func inherited(_ key: String) -> PDFValue? {
        if let value = page[PDFName(key)] { return value }
        for ancestor in chain {
          if let value = ancestor[PDFName(key)] { return value }
        }
        return nil
      }
      let media = numbers(inherited("MediaBox")) ?? [0, 0, 612, 792]
      let crop = numbers(inherited("CropBox")) ?? media
      let rotation =
        (inherited("Rotate").flatMap { value -> Int? in
          if case .integer(let number) = value { return Int(exactly: number) }
          return nil
        } ?? 0) % 360
      let normalizedRotation = ((rotation % 360) + 360) % 360
      let userUnit =
        (inherited("UserUnit").flatMap { value -> Double? in
          if case .real(let number) = value { return number }
          if case .integer(let number) = value { return Double(number) }
          return nil
        }) ?? 1
      let contentIDs = contentStreamIDs(of: page, in: graph)
      attributes.append(
        PDFPageAttributes(
          identity: "page-\(pageID.number)-\(pageID.generation)-\(index)",
          pageIndex: index, pageObjectID: pageID, mediaBox: media, cropBox: crop,
          trimBox: numbers(inherited("TrimBox")), bleedBox: numbers(inherited("BleedBox")),
          artBox: numbers(inherited("ArtBox")), rotation: normalizedRotation,
          userUnit: userUnit, contentStreamIDs: contentIDs,
          hasInheritedResources: page[PDFName("Resources")] == nil
            && chain.contains { $0[PDFName("Resources")] != nil }))
    }
    return attributes
  }

  /// P08-007: the resource categories of one page.
  public static func resources(pageID: PDFObjectID, in graph: PDFGraph)
    -> PDFPageResourceInventory
  {
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      return PDFPageResourceInventory(
        pageIndex: 0, fonts: [], images: [], forms: [], patterns: [], graphicsStates: [],
        colorSpaces: [], shadings: [], properties: [])
    }
    var resources: [PDFName: PDFValue] = [:]
    let chain = [page] + ancestorChain(of: pageID, in: graph, depth: 0)
    for entry in chain {
      if case .dictionary(let dictionary)? = resolved(entry[PDFName("Resources")], in: graph) {
        resources = dictionary
        break
      }
    }
    func names(_ key: String) -> [String] {
      guard case .dictionary(let dictionary)? = resources[PDFName(key)] else { return [] }
      return dictionary.keys.map { String(decoding: $0.bytes, as: UTF8.self) }.sorted()
    }
    // Split /XObject entries by subtype so images and reusable forms are
    // reported separately (P08-007).
    var imageNames: [String] = []
    var formNames: [String] = []
    if case .dictionary(let xobjects)? = resources[PDFName("XObject")] {
      for (name, value) in xobjects {
        let key = String(decoding: name.bytes, as: UTF8.self)
        guard case .stream(let stream)? = resolved(value, in: graph) else { continue }
        if stream.dictionary[PDFName("Subtype")] == .name(PDFName("Image")) {
          imageNames.append(key)
        } else if stream.dictionary[PDFName("Subtype")] == .name(PDFName("Form")) {
          formNames.append(key)
        }
      }
    }
    return PDFPageResourceInventory(
      pageIndex: 0, fonts: names("Font"), images: imageNames.sorted(), forms: formNames.sorted(),
      patterns: names("Pattern"), graphicsStates: names("ExtGState"),
      colorSpaces: names("ColorSpace"), shadings: names("Shading"), properties: names("Properties"))
  }

  public static func metadata(in graph: PDFGraph) -> PDFDocumentMetadata {
    var info: [PDFName: PDFValue] = [:]
    if case .reference(let infoID)? = graph.trailer[PDFName("Info")],
      case .dictionary(let dictionary)? = graph.objects[infoID]
    {
      info = dictionary
    }
    func text(_ key: String) -> String? {
      guard case .string(let data)? = info[PDFName(key)] else { return nil }
      let value = AnnotationText.decode(data)
      return value.isEmpty ? nil : value
    }
    var language: String?
    var hasXMP = false
    if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID]
    {
      if case .string(let data)? = catalog[PDFName("Lang")] {
        language = AnnotationText.decode(data)
      }
      hasXMP = catalog[PDFName("Metadata")] != nil
    }
    return PDFDocumentMetadata(
      title: text("Title"), author: text("Author"), subject: text("Subject"),
      keywords: text("Keywords"), creator: text("Creator"), producer: text("Producer"),
      creationDate: text("CreationDate"), modificationDate: text("ModDate"),
      hasFileIdentifier: graph.trailer[PDFName("ID")] != nil, hasXMPMetadata: hasXMP,
      language: language)
  }

  public static func optionalContent(in graph: PDFGraph) -> PDFOptionalContentInventory {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID],
      case .dictionary(let ocProperties)? = resolved(catalog[PDFName("OCProperties")], in: graph)
    else {
      return PDFOptionalContentInventory(groups: [], configurationNames: [], hasOrder: false)
    }
    var groups: [PDFOptionalContentInventory.Group] = []
    if case .array(let entries)? = ocProperties[PDFName("OCGs")] {
      for entry in entries {
        guard case .dictionary(let group)? = resolved(entry, in: graph) else { continue }
        let name: String?
        if case .string(let data)? = group[PDFName("Name")] {
          name = AnnotationText.decode(data)
        } else {
          name = nil
        }
        // A group's default visibility comes from the configuration's /OFF
        // list; absent that, groups are visible.
        groups.append(
          PDFOptionalContentInventory.Group(name: name, isVisibleByDefault: true))
      }
    }
    var configurationNames: [String] = []
    var hasOrder = false
    if case .dictionary(let defaults)? = resolved(ocProperties[PDFName("D")], in: graph) {
      if case .string(let data)? = defaults[PDFName("Name")] {
        configurationNames.append(AnnotationText.decode(data))
      }
      hasOrder = defaults[PDFName("Order")] != nil
    }
    return PDFOptionalContentInventory(
      groups: groups, configurationNames: configurationNames, hasOrder: hasOrder)
  }

  public static func security(in graph: PDFGraph, pageCount: Int) -> PDFSecurityInventory {
    let isEncrypted = graph.trailer[PDFName("Encrypt")] != nil
    var description: String?
    if case .reference(let id)? = graph.trailer[PDFName("Encrypt")],
      case .dictionary(let dictionary)? = graph.objects[id]
    {
      var parts: [String] = []
      if case .name(let filter)? = dictionary[PDFName("Filter")] {
        parts.append(String(decoding: filter.bytes, as: UTF8.self))
      }
      if case .integer(let version)? = dictionary[PDFName("V")] {
        parts.append("V\(version)")
      }
      if case .integer(let revision)? = dictionary[PDFName("R")] {
        parts.append("R\(revision)")
      }
      description = parts.isEmpty ? nil : parts.joined(separator: " ")
    }
    let signatures = (try? PDFSignatureInventory.signatures(in: graph)) ?? []
    // The modification policy is expressed by the session; the inventory
    // reports the conservative default for encrypted documents.
    return PDFSecurityInventory(
      isEncrypted: isEncrypted, encryptionDescription: description,
      signatureCount: signatures.count, allowsModification: !isEncrypted,
      allowsAnnotations: !isEncrypted, allowsFormFill: !isEncrypted, allowsExtraction: true)
  }

  public static func activeContent(in graph: PDFGraph) -> PDFActiveContentInventory {
    var hasXFA = false
    var hasPortfolio = false
    var hasEmbeddedFiles = false
    var hasRichMedia = false
    var has3D = false
    var hasJavaScript = false
    var hasLaunch = false
    for (_, value) in graph.objects {
      guard case .dictionary(let dictionary) = value else { continue }
      if case .dictionary(let form)? = dictionary[PDFName("AcroForm")],
        form[PDFName("XFA")] != nil
      {
        hasXFA = true
      }
      if dictionary[PDFName("Collection")] != nil { hasPortfolio = true }
      if case .dictionary(let names)? = dictionary[PDFName("Names")],
        names[PDFName("EmbeddedFiles")] != nil
      {
        hasEmbeddedFiles = true
      }
      if dictionary[PDFName("RichMediaContent")] != nil { hasRichMedia = true }
      if case .name(let subtype)? = dictionary[PDFName("Subtype")] {
        let name = String(decoding: subtype.bytes, as: UTF8.self)
        if name == "RichMedia" { hasRichMedia = true }
        if name == "3D" { has3D = true }
      }
      if dictionary[PDFName("JS")] != nil || dictionary[PDFName("JavaScript")] != nil {
        hasJavaScript = true
      }
      if case .dictionary(let action)? = dictionary[PDFName("A")],
        action[PDFName("S")] == .name(PDFName("Launch"))
      {
        hasLaunch = true
      }
      if case .dictionary(let action)? = dictionary[PDFName("OpenAction")],
        action[PDFName("S")] == .name(PDFName("Launch"))
      {
        hasLaunch = true
      }
    }
    return PDFActiveContentInventory(
      hasXFA: hasXFA, hasPortfolio: hasPortfolio, hasRichMedia: hasRichMedia, has3D: has3D,
      hasJavaScript: hasJavaScript, hasEmbeddedFiles: hasEmbeddedFiles, hasLaunchActions: hasLaunch)
  }

  /// P08-022: the operation-specific assessment.
  public static func assess(
    in graph: PDFGraph, pageCount: Int
  ) -> PDFCapabilityAssessment {
    let security = security(in: graph, pageCount: pageCount)
    let active = activeContent(in: graph)
    var reasons: [String] = []
    var canEdit = true
    var canWrite = true
    if security.isEncrypted {
      reasons.append("encrypted (unlock first)")
      canEdit = false
      canWrite = false
    }
    if security.signatureCount > 0 {
      reasons.append("digitally signed (edits would invalidate the signature)")
      canEdit = false
    }
    if active.hasXFA {
      reasons.append("XFA form content is preserved but never authored")
    }
    if active.hasRichMedia || active.has3D {
      reasons.append("rich media or 3D content is preserved but not editable")
    }
    if active.hasJavaScript || active.hasLaunchActions {
      reasons.append("document scripts and launch actions are inert")
    }
    if active.hasEmbeddedFiles {
      reasons.append("embedded files are preserved and exportable")
    }
    return PDFCapabilityAssessment(
      canView: true, canInspect: true, canEditContent: canEdit, canWrite: canWrite,
      reasons: reasons, activeContent: active, security: security)
  }

  /// P29-018: how many graphical signature marks (stamp annotations with the
  /// app's custom name) a document carries. These are visual marks, never
  /// digital signatures.
  public static func graphicalSignatureCount(
    in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) -> Int {
    var count = 0
    for pageID in pageIDs {
      guard let annotations = try? AnnotationInventory.annotations(in: graph, pageID: pageID)
      else { continue }
      for annotation in annotations
      where annotation.dictionary[PDFName("Name")] == .name(PDFName("SPDFGraphicalSignature")) {
        count += 1
      }
    }
    return count
  }

  // MARK: - Helpers

  static func ancestorChain(
    of pageID: PDFObjectID, in graph: PDFGraph, depth: Int
  ) -> [[PDFName: PDFValue]] {
    guard depth <= 64, case .dictionary(let page)? = graph.objects[pageID] else { return [] }
    var chain: [[PDFName: PDFValue]] = []
    var current = page
    var visited: Set<PDFObjectID> = [pageID]
    for _ in 0..<64 {
      guard case .reference(let parentID)? = current[PDFName("Parent")],
        !visited.contains(parentID),
        case .dictionary(let parent)? = graph.objects[parentID]
      else { break }
      visited.insert(parentID)
      chain.append(parent)
      current = parent
    }
    return chain
  }

  static func resolved(_ value: PDFValue?, in graph: PDFGraph) -> PDFValue? {
    guard let value else { return nil }
    if case .reference(let id) = value { return graph.objects[id] }
    return value
  }

  static func numbers(_ value: PDFValue?) -> [Double]? {
    guard case .array(let values)? = value else { return nil }
    let numbers = values.compactMap { entry -> Double? in
      switch entry {
      case .integer(let number): return Double(number)
      case .real(let number): return number
      default: return nil
      }
    }
    return numbers.count == 4 ? numbers : nil
  }

  static func contentStreamIDs(of page: [PDFName: PDFValue], in graph: PDFGraph)
    -> [PDFObjectID]
  {
    switch page[PDFName("Contents")] {
    case .reference(let id)?:
      return [id]
    case .array(let values)?:
      return values.compactMap { value in
        if case .reference(let id) = value { return id }
        return nil
      }
    default:
      return []
    }
  }
}
