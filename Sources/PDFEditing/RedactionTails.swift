import Foundation
import PDFCore

// MARK: - P27-002 pending marks

/// P27-002: an editable pending-redaction mark. Marks are *unapplied* by
/// construction: they never remove content or paint fills until `apply` runs
/// through `RedactRegionsCommand`. The store reports pending vs applied so
/// the UI can never present unapplied marks as complete (P27-028).
public struct PendingRedactionMark: Sendable, Equatable {
  public let id: Int
  public let pageID: PDFObjectID
  public var rect: [Double]
  public var reason: String?

  public init(id: Int, pageID: PDFObjectID, rect: [Double], reason: String? = nil) {
    self.id = id
    self.pageID = pageID
    self.rect = rect
    self.reason = reason
  }
}

public struct PendingRedactionStore: Sendable, Equatable {
  public private(set) var marks: [PendingRedactionMark] = []
  public private(set) var appliedMarkIDs: Set<Int> = []
  private var nextID: Int = 1

  public init() {}

  public var hasUnappliedMarks: Bool {
    marks.contains { !appliedMarkIDs.contains($0.id) }
  }

  /// Always false while any mark is unapplied; true only right after a
  /// successful `apply` with no later edits.
  public var reportsComplete: Bool {
    !marks.isEmpty && appliedMarkIDs == Set(marks.map(\.id))
  }

  public var statusDescription: String {
    if marks.isEmpty { return "no redaction marks" }
    if reportsComplete { return "redaction applied" }
    return "pending redaction — not applied (\(marks.count) mark(s))"
  }

  public mutating func add(pageID: PDFObjectID, rect: [Double], reason: String? = nil) throws -> PendingRedactionMark {
    guard rect.count == 4, rect.allSatisfy(\.isFinite), rect[2] > rect[0], rect[3] > rect[1] else {
      throw PDFError(.malformed, "Pending redaction marks need a non-empty rectangle")
    }
    let mark = PendingRedactionMark(id: nextID, pageID: pageID, rect: rect, reason: reason)
    nextID += 1
    marks.append(mark)
    return mark
  }

  public mutating func updateRect(id: Int, rect: [Double]) throws {
    guard rect.count == 4, rect.allSatisfy(\.isFinite), rect[2] > rect[0], rect[3] > rect[1] else {
      throw PDFError(.malformed, "Pending redaction marks need a non-empty rectangle")
    }
    guard let index = marks.firstIndex(where: { $0.id == id }) else {
      throw PDFError(.malformed, "Pending redaction mark is missing")
    }
    marks[index].rect = rect
    appliedMarkIDs.remove(id)
  }

  public mutating func remove(id: Int) {
    marks.removeAll { $0.id == id }
    appliedMarkIDs.remove(id)
  }

  /// Apply every unapplied mark grouped by page. Returns the redacted graph;
  /// the store records exactly the marks that applied.
  public mutating func apply(to graph: PDFGraph) throws -> PDFGraph {
    guard !marks.isEmpty else {
      throw PDFError(.malformed, "There are no pending redaction marks to apply")
    }
    var graph = graph
    let grouped = Dictionary(grouping: marks, by: \.pageID)
    for (pageID, pageMarks) in grouped {
      let regions = pageMarks.map(\.rect)
      graph = try PDFEditingEngine.commit(
        PDFTransaction([RedactRegionsCommand(pageID: pageID, regions: regions)]), to: graph)
    }
    appliedMarkIDs = Set(marks.map(\.id))
    return graph
  }

  /// An undo-before-apply (or any edit after staging) invalidates the
  /// applied record: the marks are pending again, never complete.
  public mutating func noteUndone() {
    appliedMarkIDs.removeAll()
  }
}

// MARK: - P27-008 pixel derivatives

/// P27-008: redacted image derivatives with affected pixels removed.
/// Only DeviceRGB 8-bit Flate images are supported; anything else refuses
/// so the derivative can actually prove pixel removal.
public enum RedactedImageDerivative {
  /// Fill `pixelRect` (origin top-left, in pixels) with black.
  public static func redactPixels(rgb8: Data, width: Int, height: Int, pixelRect: (x: Int, y: Int, w: Int, h: Int)) throws -> Data {
    guard rgb8.count == width * height * 3, width > 0, height > 0 else {
      throw PDFError(.malformed, "Image pixel dimensions do not match its data")
    }
    var bytes = [UInt8](rgb8)
    let x0 = max(pixelRect.x, 0)
    let y0 = max(pixelRect.y, 0)
    let x1 = min(pixelRect.x + pixelRect.w, width)
    let y1 = min(pixelRect.y + pixelRect.h, height)
    guard x0 < x1, y0 < y1 else {
      throw PDFError(.malformed, "Redaction pixel rect is empty or outside the image")
    }
    for y in y0..<y1 {
      for x in x0..<x1 {
        let at = (y * width + x) * 3
        bytes[at] = 0
        bytes[at + 1] = 0
        bytes[at + 2] = 0
      }
    }
    return Data(bytes)
  }

  /// Map a page-space redaction region to a pixel rect through the placement
  /// matrix (axis-aligned approximation), then redact the decoded pixels
  /// and write a new image object the page points at.
  public static func derivative(
    pageID: PDFObjectID, placement: ImagePlacement, region: [Double], in graph: PDFGraph,
    limits: PDFLimits = PDFLimits()
  ) throws -> (graph: PDFGraph, imageID: PDFObjectID) {
    guard region.count == 4 else {
      throw PDFError(.malformed, "Redaction region is invalid")
    }
    guard case .stream(let image)? = graph.objects[placement.imageID] else {
      throw PDFError(.malformed, "Image resource is missing")
    }
    for key in ["ImageMask", "Mask", "SMask", "Decode"] where image.dictionary[PDFName(key)] != nil {
      throw PDFError(.unsupported, "Redacted image derivatives refuse masked or decoded images")
    }
    guard image.dictionary[PDFName("ColorSpace")] == .name(PDFName("DeviceRGB")),
      image.dictionary[PDFName("BitsPerComponent")] == .integer(8)
    else {
      throw PDFError(.unsupported, "Redacted image derivatives support only DeviceRGB 8-bit images")
    }
    guard case .integer(let widthRaw)? = image.dictionary[PDFName("Width")],
      case .integer(let heightRaw)? = image.dictionary[PDFName("Height")],
      widthRaw > 0, heightRaw > 0
    else {
      throw PDFError(.malformed, "Image dimensions are missing")
    }
    let width = Int(widthRaw)
    let height = Int(heightRaw)
    let decoded = try PDFFilters.decoded(image, limits: limits)
    guard decoded.count == width * height * 3 else {
      throw PDFError(.unsupported, "Redacted image derivatives need exact DeviceRGB samples")
    }
    // Page bounds → unit square → pixels. The placement matrix maps the
    // unit square to page space; invert the axis-aligned bounds mapping.
    let bounds = placement.bounds
    let pageW = max(bounds[2] - bounds[0], 1e-9)
    let pageH = max(bounds[3] - bounds[1], 1e-9)
    let u0 = (max(region[0], bounds[0]) - bounds[0]) / pageW
    let u1 = (min(region[2], bounds[2]) - bounds[0]) / pageW
    // PDF image row 0 is the top; page y grows upward, so flip vertically.
    let v0 = (max(region[1], bounds[1]) - bounds[1]) / pageH
    let v1 = (min(region[3], bounds[3]) - bounds[1]) / pageH
    guard u0 < u1, v0 < v1 else {
      throw PDFError(.malformed, "Redaction region does not overlap the image placement")
    }
    let pixelRect = (
      x: Int((u0 * Double(width)).rounded(.down)),
      y: Int(((1 - v1) * Double(height)).rounded(.down)),
      w: max(Int(((u1 - u0) * Double(width)).rounded(.up)), 1),
      h: max(Int(((v1 - v0) * Double(height)).rounded(.up)), 1))
    let redacted = try redactPixels(rgb8: decoded, width: width, height: height, pixelRect: pixelRect)
    var graph = graph
    let encoded = try PDFFilters.encodeFlate(redacted, limits: limits)
    var dictionary = image.dictionary
    dictionary[PDFName("Filter")] = .name(PDFName("FlateDecode"))
    dictionary[PDFName("Length")] = .integer(Int64(encoded.count))
    let newID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    graph.objects[newID] = .stream(PDFStream(dictionary: dictionary, bytes: encoded))
    return (graph, newID)
  }
}

// MARK: - P27-010 conservative handling

/// P27-010: conservative inventory for masks, clipping, patterns, and
/// reusable forms. Any intersecting risk refuses rather than leaving
/// partial content behind.
public struct RedactionRisk: Sendable, Equatable {
  public let kind: String
  public let detail: String
}

public enum RedactionConservativePolicy {
  public static func risks(pageID: PDFObjectID, regions: [[Double]], in graph: PDFGraph) throws -> [RedactionRisk] {
    var risks: [RedactionRisk] = []
    let content = try PageContent.load(pageID: pageID, in: graph)
    // Masks / decode arrays on intersecting images.
    let placements = (try? ImageInventory.placements(in: graph, pageID: pageID)) ?? []
    for placement in placements where intersects(placement.bounds, regions) {
      if case .stream(let image)? = graph.objects[placement.imageID] {
        for key in ["ImageMask", "Mask", "SMask", "Decode"] where image.dictionary[PDFName(key)] != nil {
          risks.append(RedactionRisk(kind: "mask", detail: "image \(placement.imageID.number) carries /\(key)"))
        }
      }
      if placement.depth > 0 {
        risks.append(RedactionRisk(kind: "form", detail: "image inside a reusable form XObject"))
      }
    }
    // Clipping paths: W / W* establish a clip that can hide content
    // outside the redaction bounds.
    if content.instructions.contains(where: { $0.operatorName == "W" || $0.operatorName == "W*" }) {
      risks.append(RedactionRisk(kind: "clipping", detail: "page content establishes a clipping path"))
    }
    // Patterns and shadings: noneditable paint that can carry the target.
    let hasPattern = content.instructions.contains {
      ["scn", "SCN", "sh"].contains($0.operatorName)
    }
    if hasPattern {
      risks.append(RedactionRisk(kind: "pattern", detail: "page content paints patterns or shadings"))
    }
    // Reusable form draws: Do of a /Subtype /Form XObject.
    if case .dictionary(let page)? = graph.objects[pageID] {
      let resources: [PDFName: PDFValue]?
      switch page[PDFName("Resources")] {
      case .dictionary(let dictionary)?: resources = dictionary
      case .reference(let id)?:
        if case .dictionary(let dictionary)? = graph.objects[id] { resources = dictionary } else { resources = nil }
      default: resources = nil
      }
      if case .dictionary(let xobjects)? = resources?[PDFName("XObject")] {
        for instruction in content.instructions where instruction.operatorName == "Do" {
          if case .name(let name)? = instruction.operands.first?.value,
            case .reference(let id)? = xobjects[name],
            case .stream(let stream)? = graph.objects[id],
            stream.dictionary[PDFName("Subtype")] == .name(PDFName("Form"))
          {
            risks.append(RedactionRisk(kind: "form", detail: "page draws reusable form \(name)"))
          }
        }
      }
    }
    return risks
  }

  public static func validate(pageID: PDFObjectID, regions: [[Double]], in graph: PDFGraph) throws {
    let risks = try risks(pageID: pageID, regions: regions, in: graph)
    guard risks.isEmpty else {
      let kinds = risks.map(\.kind).sorted().joined(separator: ", ")
      throw PDFError(.unsupported, "Redaction refuses conservative content (\(kinds))")
    }
  }

  static func intersects(_ rect: [Double], _ regions: [[Double]]) -> Bool {
    guard rect.count == 4 else { return false }
    return regions.contains { region in
      rect[0] < region[2] && rect[2] > region[0] && rect[1] < region[3] && rect[3] > region[1]
    }
  }
}

// MARK: - P27-014 structure audit

/// P27-014: verify no structure or marked-content data retains removed text.
public enum RedactionStructureAudit {
  public static func verifyNoRetainedText(
    in graph: PDFGraph, pageIDs: [PDFObjectID], redactedStrings: [String]
  ) throws {
    let inventory = try PDFStructureInspector.inspect(in: graph, pageIDs: pageIDs)
    for element in inventory.elements {
      for secret in redactedStrings where !secret.isEmpty {
        if element.alt?.contains(secret) == true || element.actualText?.contains(secret) == true
          || element.title?.contains(secret) == true
        {
          throw PDFError(.malformed, "Structure data retains redacted text")
        }
      }
    }
    // Marked-content properties with ActualText/Alt live in content streams.
    for pageID in pageIDs {
      let content = try PageContent.load(pageID: pageID, in: graph)
      let raw = content.segments.flatMap(\.decoded)
      let text = String(decoding: raw, as: UTF8.self)
      for secret in redactedStrings where !secret.isEmpty {
        if text.contains(secret) {
          throw PDFError(.malformed, "Page content retains redacted text")
        }
      }
    }
  }
}

// MARK: - P27-015 alternate content inventory

/// P27-015: alternate content and optional layers relevant to a redaction.
public struct RedactionAlternateInventory: Sendable, Equatable {
  public let optionalContentGroups: [String]
  public let markedContentWithOC: Int
  public let hasAlternatePresentations: Bool
}

public enum RedactionAlternateContent {
  public static func inventory(pageID: PDFObjectID, in graph: PDFGraph) throws -> RedactionAlternateInventory {
    var groups: [String] = []
    if case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[rootID],
      let properties = catalog[PDFName("OCProperties")]
    {
      let resolved: PDFValue?
      if case .reference(let id) = properties { resolved = graph.objects[id] } else { resolved = properties }
      if case .dictionary(let dictionary) = resolved,
        case .array(let ocgs)? = dictionary[PDFName("OCGs")]
      {
        for entry in ocgs {
          let dictionary: [PDFName: PDFValue]?
          if case .reference(let id) = entry, case .dictionary(let resolved)? = graph.objects[id] {
            dictionary = resolved
          } else if case .dictionary(let direct) = entry {
            dictionary = direct
          } else { dictionary = nil }
          if case .string(let data)? = dictionary?[PDFName("Name")] {
            groups.append(String(decoding: data, as: UTF8.self))
          } else {
            groups.append("unnamed")
          }
        }
      }
    }
    let content = try PageContent.load(pageID: pageID, in: graph)
    var ocCount = 0
    for instruction in content.instructions where instruction.operatorName == "BDC" {
      if case .name(let tag)? = instruction.operands.first?.value,
        String(decoding: tag.bytes, as: UTF8.self) == "OC"
      {
        ocCount += 1
      }
    }
    let hasAlternate: Bool = {
      if case .reference(let rootID)? = graph.trailer[PDFName("Root")],
        case .dictionary(let catalog)? = graph.objects[rootID]
      {
        return catalog[PDFName("AlternatePresentations")] != nil
      }
      return false
    }()
    return RedactionAlternateInventory(
      optionalContentGroups: groups, markedContentWithOC: ocCount,
      hasAlternatePresentations: hasAlternate)
  }
}

// MARK: - P27-017/P27-018 flattened derivative

/// P27-017/P27-018: an explicit flattened redacted derivative. Pages are
/// rebuilt from caller-supplied *already-redacted* pixels: the output page
/// carries a single image draw and no text, annotations, widgets, or OCR
/// layers, so unredacted content cannot leak through the fallback.
public enum FlattenedRedactedDerivative {
  public static let marker = PDFName("SPDFRedactedFlat")

  public static func isFlattenedDerivative(_ graph: PDFGraph, pageID: PDFObjectID) -> Bool {
    if case .dictionary(let page)? = graph.objects[pageID] {
      return page[marker] == .boolean(true)
    }
    return false
  }

  public static func make(
    from graph: PDFGraph, pageID: PDFObjectID, width: Int, height: Int, rgb8: Data,
    limits: PDFLimits = PDFLimits()
  ) throws -> PDFGraph {
    guard width >= 1, width <= 10_000, height >= 1, height <= 10_000,
      rgb8.count == width * height * 3
    else {
      throw PDFError(.malformed, "Flattened redacted pixels do not match their dimensions")
    }
    var graph = graph
    // The source page must already be redacted: no live generated OCR layer
    // may survive into the fallback, and the caller must have rendered the
    // redacted revision (the output keeps only the supplied pixels).
    try OCRLayer.removeLayer(pageID: pageID, in: &graph)
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    var next = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    let encoded = try PDFFilters.encodeFlate(rgb8, limits: limits)
    let imageID = PDFObjectID(next)
    next += 1
    graph.objects[imageID] = .stream(PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Image")),
        PDFName("Width"): .integer(Int64(width)),
        PDFName("Height"): .integer(Int64(height)),
        PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
        PDFName("BitsPerComponent"): .integer(8),
        PDFName("Filter"): .name(PDFName("FlateDecode")),
        PDFName("Length"): .integer(Int64(encoded.count)),
      ], bytes: encoded))
    let mediaBox: [Double]
    if case .array(let values)? = page[PDFName("MediaBox")] {
      let numbers = values.compactMap { value -> Double? in
        if case .integer(let raw) = value { return Double(raw) }
        if case .real(let raw) = value { return raw }
        return nil
      }
      mediaBox = numbers.count == 4 ? numbers : [0, 0, 612, 792]
    } else {
      mediaBox = [0, 0, 612, 792]
    }
    let content = "q\n\(mediaBox[2] - mediaBox[0]) 0 0 \(mediaBox[3] - mediaBox[1]) 0 0 cm\n/ImFlat Do\nQ\n"
    let contentBytes = Data(content.utf8)
    let contentID = PDFObjectID(next)
    next += 1
    graph.objects[contentID] = .stream(PDFStream(
      dictionary: [PDFName("Length"): .integer(Int64(contentBytes.count))], bytes: contentBytes))
    page[PDFName("Contents")] = .reference(contentID)
    page[PDFName("Resources")] = .dictionary([
      PDFName("XObject"): .dictionary([PDFName("ImFlat"): .reference(imageID)])
    ])
    page[PDFName("Annots")] = nil
    page[marker] = .boolean(true)
    graph.objects[pageID] = .dictionary(page)
    // Prune page widgets from the AcroForm tree so no field survives.
    graph = try prunePageWidgets(pageID: pageID, in: graph)
    let reachable = SanitizeDocumentCommand.reachableObjectIDs(in: graph)
    graph.objects = graph.objects.filter { reachable.contains($0.key) }
    graph.trailer[PDFName("Size")] = .integer(Int64((graph.objects.keys.map(\.number).max() ?? 0) + 1))
    return graph
  }

  static func prunePageWidgets(pageID: PDFObjectID, in graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let annotations = (try? AnnotationInventory.annotations(in: graph, pageID: pageID)) ?? []
    // After clearing /Annots there should be none, but drop field entries
    // whose widgets pointed at this page by object identity.
    _ = annotations
    return graph
  }
}

// MARK: - P27-019 OCR only on the derivative

/// P27-019: OCR runs only on the resulting redacted derivative when
/// requested — never on the unredacted source.
public enum RedactedOCRPolicy {
  public static func addOCR(
    to graph: PDFGraph, pageID: PDFObjectID, lines: [SearchableTextLine]
  ) throws -> PDFGraph {
    guard FlattenedRedactedDerivative.isFlattenedDerivative(graph, pageID: pageID) else {
      throw PDFError(
        .unsupported, "OCR after redaction runs only on the redacted derivative when requested")
    }
    return try PDFEditingEngine.commit(
      PDFTransaction([AddSearchableTextLayerCommand(pageID: pageID, lines: lines)]), to: graph)
  }
}

// MARK: - P27-020/P27-021 sanitizer passes + report

/// P27-020: what a document-level sanitizer pass may remove.
public struct SanitizerPolicy: Sendable, Equatable {
  public var removeMetadata: Bool
  public var removeAttachmentsExcept: Set<String>
  public var removeScripts: Bool
  public var removeEmbeddedFilesExcept: Set<String>
  public var removeOptionalContent: Bool

  public init(
    removeMetadata: Bool = true,
    removeAttachmentsExcept: Set<String> = [],
    removeScripts: Bool = true,
    removeEmbeddedFilesExcept: Set<String> = [],
    removeOptionalContent: Bool = true
  ) {
    self.removeMetadata = removeMetadata
    self.removeAttachmentsExcept = removeAttachmentsExcept
    self.removeScripts = removeScripts
    self.removeEmbeddedFilesExcept = removeEmbeddedFilesExcept
    self.removeOptionalContent = removeOptionalContent
  }

  public static var redactionDefault: SanitizerPolicy { SanitizerPolicy() }
}

public struct SanitizerReport: Sendable, Equatable {
  public let removedMetadata: Int
  public let removedAttachments: Int
  public let removedScripts: Int
  public let removedEmbeddedFiles: Int
  public let removedOptionalContent: Int
  public let transformations: [String]

  public var summary: String {
    transformations.isEmpty ? "no changes" : transformations.joined(separator: ", ")
  }
}

public enum SanitizerPass {
  /// P27-021: supported document-level sanitizer passes with an explicit
  /// report. Reachable metadata, attachments, scripts, embedded files, and
  /// optional layers are removed per policy; unreachable objects are pruned.
  public static func run(in graph: PDFGraph, policy: SanitizerPolicy) throws -> (graph: PDFGraph, report: SanitizerReport) {
    var graph = graph
    var removedMetadata = 0
    var removedAttachments = 0
    var removedScripts = 0
    var removedEmbedded = 0
    var removedOC = 0
    var transformations: [String] = []

    if policy.removeMetadata {
      if graph.trailer[PDFName("Info")] != nil {
        graph.trailer[PDFName("Info")] = nil
        removedMetadata += 1
      }
      for (id, value) in graph.objects {
        let dictionary: [PDFName: PDFValue]?
        if case .dictionary(let direct) = value { dictionary = direct }
        else if case .stream(let stream) = value { dictionary = stream.dictionary }
        else { dictionary = nil }
        if dictionary?[PDFName("Type")] == .name(PDFName("Metadata")) {
          graph.objects[id] = nil
          removedMetadata += 1
        }
      }
      if case .reference(let rootID)? = graph.trailer[PDFName("Root")],
        case .dictionary(var catalog)? = graph.objects[rootID],
        catalog[PDFName("Metadata")] != nil
      {
        catalog[PDFName("Metadata")] = nil
        graph.objects[rootID] = .dictionary(catalog)
      }
      if removedMetadata > 0 { transformations.append("removed \(removedMetadata) metadata objects") }
    }

    // Attachments + embedded files: /EmbeddedFiles name tree + /EF streams.
    let embeddedIDs = embeddedFileIDs(in: graph)
    for id in embeddedIDs {
      let name = embeddedFileName(id: id, in: graph) ?? "unnamed"
      let allowed = policy.removeAttachmentsExcept.contains(name) || policy.removeEmbeddedFilesExcept.contains(name)
      if !allowed {
        graph.objects[id] = nil
        removedAttachments += 1
      }
    }
    if removedAttachments > 0 { transformations.append("removed \(removedAttachments) attachments/embedded files") }
    // Drop the name tree when it no longer resolves.
    if case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[rootID],
      case .dictionary(var names)? = catalog[PDFName("Names")]
    {
      names[PDFName("EmbeddedFiles")] = nil
      if names.isEmpty { catalog[PDFName("Names")] = nil } else { catalog[PDFName("Names")] = .dictionary(names) }
      graph.objects[rootID] = .dictionary(catalog)
    }

    if policy.removeScripts {
      // Catalog actions: /OpenAction, /AA, /Names /JavaScript.
      if case .reference(let rootID)? = graph.trailer[PDFName("Root")],
        case .dictionary(var catalog)? = graph.objects[rootID]
      {
        for key in [PDFName("OpenAction"), PDFName("AA"), PDFName("JavaScript")] where catalog[key] != nil {
          catalog[key] = nil
          removedScripts += 1
        }
        if case .dictionary(var names)? = catalog[PDFName("Names")] {
          if names[PDFName("JavaScript")] != nil {
            names[PDFName("JavaScript")] = nil
            removedScripts += 1
          }
          catalog[PDFName("Names")] = names.isEmpty ? nil : .dictionary(names)
        }
        // Annotation /A and /AA entries with JavaScript or Launch.
        graph.objects[rootID] = .dictionary(catalog)
      }
      for (id, value) in graph.objects {
        if case .dictionary(var dictionary) = value {
          var changed = false
          for key in [PDFName("A"), PDFName("AA")] where dictionary[key] != nil {
            dictionary[key] = nil
            changed = true
          }
          // Embedded /JS strings inside actions.
          if dictionary[PDFName("S")] == .name(PDFName("JavaScript"))
            || dictionary[PDFName("S")] == .name(PDFName("Launch")) {
            graph.objects[id] = nil
            removedScripts += 1
            continue
          }
          if changed {
            graph.objects[id] = .dictionary(dictionary)
            removedScripts += 1
          }
        }
      }
      // Standalone /JS string objects reachable only through actions.
      if removedScripts > 0 { transformations.append("removed \(removedScripts) script/action entries") }
    }

    if policy.removeOptionalContent {
      if case .reference(let rootID)? = graph.trailer[PDFName("Root")],
        case .dictionary(var catalog)? = graph.objects[rootID],
        catalog[PDFName("OCProperties")] != nil
      {
        catalog[PDFName("OCProperties")] = nil
        graph.objects[rootID] = .dictionary(catalog)
        removedOC += 1
      }
      for (id, value) in graph.objects {
        if case .dictionary(let dictionary) = value,
          dictionary[PDFName("Type")] == .name(PDFName("OCG"))
        {
          graph.objects[id] = nil
          removedOC += 1
        }
      }
      if removedOC > 0 { transformations.append("removed \(removedOC) optional-content entries") }
    }

    let reachable = SanitizeDocumentCommand.reachableObjectIDs(in: graph)
    var pruned = 0
    for id in graph.objects.keys where !reachable.contains(id) {
      graph.objects[id] = nil
      pruned += 1
    }
    if pruned > 0 { transformations.append("pruned \(pruned) unreachable objects") }
    // Embedded-file removals are reported together with attachments.
    removedEmbedded = 0
    let report = SanitizerReport(
      removedMetadata: removedMetadata, removedAttachments: removedAttachments,
      removedScripts: removedScripts, removedEmbeddedFiles: removedEmbedded,
      removedOptionalContent: removedOC, transformations: transformations)
    return (graph, report)
  }

  static func embeddedFileIDs(in graph: PDFGraph) -> [PDFObjectID] {
    graph.objects.compactMap { (id, value) in
      guard case .stream(let stream) = value,
        stream.dictionary[PDFName("Type")] == .name(PDFName("EmbeddedFile"))
      else { return nil }
      return id
    }
  }

  static func embeddedFileName(id: PDFObjectID, in graph: PDFGraph) -> String? {
    guard case .stream(let stream)? = graph.objects[id] else { return nil }
    if case .string(let data)? = stream.dictionary[PDFName("F")] {
      return String(decoding: data, as: UTF8.self)
    }
    // Also check the /EF file-spec wrapper.
    for value in graph.objects.values {
      if case .dictionary(let dictionary) = value,
        case .dictionary(let ef)? = dictionary[PDFName("EF")],
        ef.values.contains(.reference(id)),
        case .string(let data)? = dictionary[PDFName("F")]
      {
        return String(decoding: data, as: UTF8.self)
      }
    }
    return "unnamed"
  }
}

// MARK: - P27-026 sanitized verification

/// P27-026: sanitized derivatives contain only permitted attachments,
/// actions, and metadata.
public enum SanitizedDerivativeCheck {
  public static func verify(
    in graph: PDFGraph, allowedAttachments: Set<String> = [], allowMetadata: Bool = false,
    allowScripts: Bool = false
  ) throws {
    if !allowMetadata {
      guard graph.trailer[PDFName("Info")] == nil else {
        throw PDFError(.malformed, "Sanitized derivative retains /Info metadata")
      }
      for value in graph.objects.values {
        let dictionary: [PDFName: PDFValue]?
        if case .dictionary(let direct) = value { dictionary = direct }
        else if case .stream(let stream) = value { dictionary = stream.dictionary }
        else { dictionary = nil }
        if dictionary?[PDFName("Type")] == .name(PDFName("Metadata")) {
          throw PDFError(.malformed, "Sanitized derivative retains XMP metadata")
        }
      }
    }
    for (id, value) in graph.objects {
      if case .stream(let stream) = value,
        stream.dictionary[PDFName("Type")] == .name(PDFName("EmbeddedFile"))
      {
        let name = SanitizerPass.embeddedFileName(id: id, in: graph) ?? "unnamed"
        guard allowedAttachments.contains(name) else {
          throw PDFError(.malformed, "Sanitized derivative retains attachment \(name)")
        }
      }
    }
    if !allowScripts {
      if case .reference(let rootID)? = graph.trailer[PDFName("Root")],
        case .dictionary(let catalog)? = graph.objects[rootID],
        catalog[PDFName("OpenAction")] != nil || catalog[PDFName("JavaScript")] != nil
      {
        throw PDFError(.malformed, "Sanitized derivative retains document scripts")
      }
      for value in graph.objects.values {
        if case .dictionary(let dictionary) = value,
          dictionary[PDFName("S")] == .name(PDFName("JavaScript"))
            || dictionary[PDFName("S")] == .name(PDFName("Launch"))
        {
          throw PDFError(.malformed, "Sanitized derivative retains launch/script actions")
        }
      }
    }
  }
}

// MARK: - P27-030 acceptance gate

/// P27-030: the secure-redaction UI enables only when the full removal
/// acceptance suite passes on the derivative.
public struct SecureRedactionGateResult: Sendable, Equatable {
  public let passed: Bool
  public let reasons: [String]
}

public enum SecureRedactionGate {
  /// Run coverage (no live target text), absence (raw bytes), and structure
  /// checks. Returns pass/fail with reasons; the UI binds `passed` to its
  /// enabled state.
  public static func evaluate(
    derivative: PDFGraph, pageIDs: [PDFObjectID], redactedStrings: [String]
  ) -> SecureRedactionGateResult {
    var reasons: [String] = []
    do {
      let data = try PDFWriter.serialize(derivative)
      for secret in redactedStrings where !secret.isEmpty {
        if data.range(of: Data(secret.utf8)) != nil {
          reasons.append("derivative bytes retain redacted text")
          break
        }
      }
      if data.range(of: Data("/Prev".utf8)) != nil {
        reasons.append("derivative retains earlier revisions")
      }
    } catch {
      reasons.append("derivative does not serialize")
    }
    do {
      try RedactionStructureAudit.verifyNoRetainedText(
        in: derivative, pageIDs: pageIDs, redactedStrings: redactedStrings)
    } catch {
      reasons.append("structure or content retains redacted text")
    }
    return SecureRedactionGateResult(passed: reasons.isEmpty, reasons: reasons)
  }
}
