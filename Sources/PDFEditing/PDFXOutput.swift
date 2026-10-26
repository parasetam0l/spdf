import Foundation
import PDFCore

// PRE-03: selected PDF/X output profiles. The declared profile is a supported
// subset (boxes, embedded fonts, output intent, XMP identification, permitted
// transparency/RGB rules); color-managed conversion is PRE-05 and is not claimed.
// A final file is self-validated and independently validated with the shipped
// Tools/PRE-03-04/pdfx_validate.py script.

public enum PDFXProfile: String, Sendable, Equatable, CaseIterable, Codable {
  case x4 = "PDF/X-4"
  case x1a2003 = "PDF/X-1a:2003"

  public var title: String {
    switch self {
    case .x4: return "PDF/X-4 (declared subset)"
    case .x1a2003: return "PDF/X-1a:2003 (declared subset)"
    }
  }
  public var pdfVersion: String {
    switch self {
    case .x4: return "1.6"
    case .x1a2003: return "1.3"
    }
  }
  public var allowsTransparency: Bool { self == .x4 }
  public var allowsRGB: Bool { self == .x4 }
  public var identification: String {
    switch self {
    case .x4: return "PDF/X-4"
    case .x1a2003: return "PDF/X-1a:2003"
    }
  }
  public var declaredLimits: String {
    switch self {
    case .x4:
      return "Declared subset: MediaBox/CropBox/TrimBox present and nested, embedded fonts only, declared CMYK output intent, PDF/X identification XMP, annotations/forms flattened, no encryption. Transparency and RGB content are permitted; the output intent is a declared custom CMYK condition, not a colorimetric SWOP/Pantone match."
    case .x1a2003:
      return "Declared subset: the X-4 requirements plus no transparency and no RGB content. Unsupported transparency and RGB are refused, not rasterized or converted; color-managed conversion is not provided (PRE-05)."
    }
  }
}

/// Deterministic declared ICC output condition. It is structurally valid ICC,
/// but it is an sPDF-declared condition rather than a measured press profile.
public enum PDFXICCProfile {
  public static let conditionIdentifier = "sPDF Declared CMYK"
  public static let conditionInfo = "Declared CMYK output condition for sPDF PDF/X subset validation"
  public static let registryName = "sPDF declared conditions"

  public static func declaredCMYK() -> Data {
    func u32(_ value: Int) -> Data { Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
    func u16(_ value: Int) -> Data { Data([UInt8((value >> 8) & 255), UInt8(value & 255)]) }
    func s15(_ value: Double) -> Data { u32(Int((value * 65536).rounded())) }
    func tag(_ signature: String, _ payload: Data) -> Data {
      var data = Data(signature.utf8)
      data.append(u32(0))
      data.append(u32(payload.count))
      data.append(payload)
      return data
    }
    let description = Data("sPDF Declared CMYK".utf8)
    var descPayload = Data()
    descPayload.append(u32(0))
    descPayload.append(u32(description.count + 1))
    descPayload.append(description)
    descPayload.append(0)
    descPayload.append(u16(0))
    descPayload.append(u32(0))
    descPayload.append(u16(0))
    descPayload.append(0)
    descPayload.append(u16(0))
    let descriptionTag = tag("desc", descPayload)
    var whitepoint = tag("XYZ ", u32(0))
    whitepoint.append(s15(0.9642))
    whitepoint.append(s15(1.0))
    whitepoint.append(s15(0.8249))
    let copyright = Data("No copyright. Declared output condition.".utf8)
    var cprtPayload = u32(0)
    cprtPayload.append(copyright)
    cprtPayload.append(0)
    let copyrightTag = tag("cprt", cprtPayload)
    let tagData = descriptionTag + whitepoint + copyrightTag
    var header = Data()
    header.append(u32(0))
    header.append(Data([0, 0, 0, 0]))
    header.append(u32(0x0430_0000))
    header.append(Data("prtr".utf8))
    header.append(Data("CMYK".utf8))
    header.append(Data("XYZ ".utf8))
    header.append(u16(2026))
    header.append(u16(10))
    header.append(u16(26))
    header.append(u16(12))
    header.append(u16(0))
    header.append(u16(0))
    header.append(Data("acsp".utf8))
    header.append(Data("APPL".utf8))
    header.append(u32(0))
    header.append(Data("sPDF".utf8))
    header.append(u32(0))
    header.append(Data(repeating: 0, count: 8))
    header.append(u32(0))
    header.append(s15(0.9642))
    header.append(s15(1.0))
    header.append(s15(0.8249))
    header.append(Data("sPDF".utf8))
    header.append(Data(repeating: 0, count: 16))
    header.append(Data(repeating: 0, count: 28))
    header.append(u32(3))
    let total = header.count + tagData.count
    var data = header
    data.append(tagData)
    let sizeBytes = u32(total)
    data.replaceSubrange(0..<4, with: sizeBytes)
    return data
  }
}

public struct PDFXPageBox: Sendable, Equatable {
  public let pageIndex: Int
  public let mediaBox: [Double]
  public let cropBox: [Double]?
  public let trimBox: [Double]?
  public let bleedBox: [Double]?
  public var hasRequiredBox: Bool { trimBox != nil }
  public init(pageIndex: Int, mediaBox: [Double], cropBox: [Double]?, trimBox: [Double]?, bleedBox: [Double]?) {
    self.pageIndex = pageIndex; self.mediaBox = mediaBox; self.cropBox = cropBox
    self.trimBox = trimBox; self.bleedBox = bleedBox
  }
}

public struct PDFXInventory: Sendable, Equatable {
  public let pages: [PDFXPageBox]
  public let fontsTotal: Int
  public let fontsNotEmbedded: Int
  public let unembeddedFontNames: [String]
  public let rgbContentUses: Int
  public let rgbImageNames: [String]
  public let transparencyUses: Int
  public let annotationCount: Int
  public let formFieldCount: Int
  public let hasOutputIntent: Bool
  public let outputIntentHasICC: Bool
  public let hasPDFXIdentification: Bool
  public let identifiedVersion: String?
  public let encrypted: Bool
  public let unsupportedFilters: [String]
  public let lowResolutionImages: Int
  public init(
    pages: [PDFXPageBox], fontsTotal: Int, fontsNotEmbedded: Int,
    unembeddedFontNames: [String], rgbContentUses: Int, rgbImageNames: [String],
    transparencyUses: Int, annotationCount: Int, formFieldCount: Int,
    hasOutputIntent: Bool, outputIntentHasICC: Bool, hasPDFXIdentification: Bool,
    identifiedVersion: String?, encrypted: Bool, unsupportedFilters: [String],
    lowResolutionImages: Int
  ) {
    self.pages = pages; self.fontsTotal = fontsTotal; self.fontsNotEmbedded = fontsNotEmbedded
    self.unembeddedFontNames = unembeddedFontNames; self.rgbContentUses = rgbContentUses
    self.rgbImageNames = rgbImageNames; self.transparencyUses = transparencyUses
    self.annotationCount = annotationCount; self.formFieldCount = formFieldCount
    self.hasOutputIntent = hasOutputIntent; self.outputIntentHasICC = outputIntentHasICC
    self.hasPDFXIdentification = hasPDFXIdentification
    self.identifiedVersion = identifiedVersion; self.encrypted = encrypted
    self.unsupportedFilters = unsupportedFilters; self.lowResolutionImages = lowResolutionImages
  }
}

public struct PDFXTransformation: Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable { case pageBoxes, outputIntent, identification, flattenAnnotations, flattenForms, version }
  public let kind: Kind
  public let detail: String
  public let count: Int
  public init(kind: Kind, detail: String, count: Int) {
    self.kind = kind; self.detail = detail; self.count = count
  }
}

public struct PDFXExportOptions: Sendable, Equatable {
  public var flattenAnnotations: Bool
  public var flattenFormFields: Bool
  public var addMissingTrimBox: Bool
  public init(flattenAnnotations: Bool = true, flattenFormFields: Bool = true, addMissingTrimBox: Bool = true) {
    self.flattenAnnotations = flattenAnnotations
    self.flattenFormFields = flattenFormFields
    self.addMissingTrimBox = addMissingTrimBox
  }
  public static var printDelivery: PDFXExportOptions { .init() }
}

public struct PDFXExportPlan: Sendable, Equatable {
  public let profile: PDFXProfile
  public let inventory: PDFXInventory
  public let options: PDFXExportOptions
  public let transformations: [PDFXTransformation]
  public let refusals: [String]
  public let warnings: [String]
  public init(profile: PDFXProfile, inventory: PDFXInventory, options: PDFXExportOptions, transformations: [PDFXTransformation], refusals: [String], warnings: [String]) {
    self.profile = profile; self.inventory = inventory; self.options = options
    self.transformations = transformations; self.refusals = refusals; self.warnings = warnings
  }
  public var isExportable: Bool { refusals.isEmpty }
  public var summary: String {
    var lines = ["\(profile.title): \(isExportable ? "ready" : "refused") for \(inventory.pages.count) page(s)"]
    for transformation in transformations { lines.append("  fix: \(transformation.detail) (\(transformation.count))") }
    for warning in warnings { lines.append("  warning: \(warning)") }
    for refusal in refusals { lines.append("  refused: \(refusal)") }
    return lines.joined(separator: "\n")
  }
}

public struct PDFXValidationResult: Sendable, Equatable {
  public let profile: PDFXProfile
  public let passed: Bool
  public let issues: [String]
  public let checks: [String]
  public init(profile: PDFXProfile, passed: Bool, issues: [String], checks: [String]) {
    self.profile = profile; self.passed = passed; self.issues = issues; self.checks = checks
  }
  public var summary: String {
    passed ? "PDF/X \(profile.identification) declared-subset validation passed." : "PDF/X validation failed: " + issues.joined(separator: "; ")
  }
}

public enum PDFXExporter {
  public static func inventory(_ graph: PDFGraph, pageIDs: [PDFObjectID], profile: PDFXProfile) -> PDFXInventory {
    var pages: [PDFXPageBox] = []
    func box(_ dictionary: [PDFName: PDFValue], _ key: String) -> [Double]? {
      guard case .array(let values)? = dictionary[PDFName(key)] else { return nil }
      let numbers = values.compactMap { value -> Double? in
        switch value { case .integer(let n): return Double(n); case .real(let n): return n; default: return nil }
      }
      return numbers.count == 4 ? numbers : nil
    }
    for (index, pageID) in pageIDs.enumerated() {
      guard case .dictionary(let page)? = graph.objects[pageID] else { continue }
      pages.append(PDFXPageBox(pageIndex: index, mediaBox: box(page, "MediaBox") ?? [0, 0, 612, 792], cropBox: box(page, "CropBox"), trimBox: box(page, "TrimBox"), bleedBox: box(page, "BleedBox")))
    }
    let fonts = PDFFontInventory.fonts(in: graph, pageIDs: pageIDs)
    let notEmbedded = fonts.filter { !$0.isEmbedded }
    let images = (try? PDFImageInventory.images(in: graph, pageIDs: pageIDs)) ?? []
    let rgbImages = images.filter { $0.colorSpace == "DeviceRGB" || $0.colorSpace.contains("ICCBased") }
    var rgbUses = 0
    for pageID in pageIDs {
      guard let content = try? PageContent.load(pageID: pageID, in: graph) else { continue }
      for instruction in content.instructions {
        switch instruction.operatorName {
        case "rg", "RG": rgbUses += 1
        default: break
        }
      }
    }
    let annotations = pageIDs.reduce(0) { $0 + ((try? AnnotationInventory.annotations(in: graph, pageID: $1))?.count ?? 0) }
    let fields = (try? FormInventory.fields(in: graph, pageIDs: pageIDs)) ?? []
    let outputIntent = catalogValue("OutputIntents", in: graph)
    var hasICC = false
    if case .array(let intents)? = outputIntent {
      for intent in intents {
        let resolvedIntent: [PDFName: PDFValue]?
        if case .dictionary(let direct) = intent { resolvedIntent = direct }
        else if case .reference(let id) = intent, case .dictionary(let indirect)? = graph.objects[id] { resolvedIntent = indirect }
        else { resolvedIntent = nil }
        if let resolvedIntent, verifiedICC(resolvedIntent, in: graph) { hasICC = true }
      }
    }
    var identification: String?
    var hasIdentification = false
    if let xmp = xmpText(in: graph) {
      for profileName in ["PDF/X-4", "PDF/X-1a:2003", "PDF/X-1a:2001", "PDF/X-3:2003", "PDF/X-1:2001"] where xmp.contains(profileName) {
        identification = profileName; hasIdentification = true
      }
    }
    var unsupportedFilters: [String] = []
    for (_, value) in graph.objects {
      guard case .stream(let stream) = value, let filter = stream.dictionary[PDFName("Filter")] else { continue }
      func names(_ value: PDFValue) -> [String] {
        switch value {
        case .name(let name): return [String(decoding: name.bytes, as: UTF8.self)]
        case .array(let values): return values.flatMap(names)
        default: return []
        }
      }
      for name in names(filter) where ["LZWDecode", "RunLengthDecode"].contains(name) {
        unsupportedFilters.append(name)
      }
    }
    let lowResolution = images.filter { image in
      let dpiX = image.bounds.count == 4 && image.bounds[2] > image.bounds[0] ? Double(image.width) / ((image.bounds[2] - image.bounds[0]) / 72) : 0
      return dpiX < 150
    }
    return PDFXInventory(
      pages: pages, fontsTotal: fonts.count, fontsNotEmbedded: notEmbedded.count,
      unembeddedFontNames: notEmbedded.map { $0.baseName.isEmpty ? $0.resource : $0.baseName },
      rgbContentUses: rgbUses, rgbImageNames: rgbImages.map(\.name),
      transparencyUses: PDFCompatibilityScan.scan(in: graph).transparency,
      annotationCount: annotations, formFieldCount: fields.count,
      hasOutputIntent: outputIntent != nil, outputIntentHasICC: hasICC,
      hasPDFXIdentification: hasIdentification, identifiedVersion: identification,
      encrypted: graph.trailer[PDFName("Encrypt")] != nil,
      unsupportedFilters: Array(Set(unsupportedFilters)).sorted(),
      lowResolutionImages: lowResolution.count)
  }

  public static func plan(
    _ graph: PDFGraph, pageIDs: [PDFObjectID], profile: PDFXProfile,
    options: PDFXExportOptions = .printDelivery
  ) -> PDFXExportPlan {
    let inventory = inventory(graph, pageIDs: pageIDs, profile: profile)
    var refusals: [String] = []
    var warnings: [String] = []
    var transformations: [PDFXTransformation] = []
    if inventory.encrypted { refusals.append("Encrypted documents cannot be exported as PDF/X") }
    if inventory.fontsNotEmbedded > 0 {
      refusals.append("\(inventory.fontsNotEmbedded) font(s) are not embedded: " + inventory.unembeddedFontNames.joined(separator: ", "))
    }
    if !inventory.unsupportedFilters.isEmpty {
      refusals.append("Unsupported filters for PDF/X: " + inventory.unsupportedFilters.joined(separator: ", "))
    }
    if !profile.allowsTransparency && inventory.transparencyUses > 0 {
      refusals.append("PDF/X-1a requires flattened transparency; this declared profile refuses instead of rasterizing (\(inventory.transparencyUses) use(s))")
    }
    if !profile.allowsRGB && (inventory.rgbContentUses > 0 || !inventory.rgbImageNames.isEmpty) {
      refusals.append("PDF/X-1a declared subset refuses DeviceRGB content/images instead of converting color (\(inventory.rgbContentUses) operator(s), \(inventory.rgbImageNames.count) image(s))")
    }
    let missingTrim = inventory.pages.filter { $0.trimBox == nil }
    if !missingTrim.isEmpty {
      if options.addMissingTrimBox {
        transformations.append(PDFXTransformation(kind: .pageBoxes, detail: "add missing TrimBox from CropBox/MediaBox", count: missingTrim.count))
      } else {
        refusals.append("\(missingTrim.count) page(s) have no TrimBox")
      }
    }
    if !inventory.hasOutputIntent || !inventory.outputIntentHasICC {
      transformations.append(PDFXTransformation(kind: .outputIntent, detail: "write declared CMYK output intent (ICC)", count: 1))
    }
    if !inventory.hasPDFXIdentification || inventory.identifiedVersion != profile.identification {
      transformations.append(PDFXTransformation(kind: .identification, detail: "write PDF/X identification XMP for \(profile.identification)", count: 1))
    }
    if options.flattenAnnotations && inventory.annotationCount > 0 {
      transformations.append(PDFXTransformation(kind: .flattenAnnotations, detail: "flatten annotations into page content", count: inventory.annotationCount))
    }
    if options.flattenFormFields && inventory.formFieldCount > 0 {
      transformations.append(PDFXTransformation(kind: .flattenForms, detail: "flatten form fields into page content", count: inventory.formFieldCount))
    }
    transformations.append(PDFXTransformation(kind: .version, detail: "set PDF version \(profile.pdfVersion)", count: 1))
    if inventory.lowResolutionImages > 0 {
      warnings.append("\(inventory.lowResolutionImages) image(s) below 150 dpi at placement; press QA may reject")
    }
    return PDFXExportPlan(profile: profile, inventory: inventory, options: options, transformations: transformations, refusals: refusals, warnings: warnings)
  }

  public static func stage(plan: PDFXExportPlan, graph: PDFGraph, pageIDs: [PDFObjectID], limits: PDFLimits = PDFLimits()) throws -> (graph: PDFGraph, plan: PDFXExportPlan) {
    var work = graph
    if plan.options.flattenAnnotations, plan.inventory.annotationCount > 0 {
      for pageID in pageIDs
      where !FlattenAnnotationsCommand.flattenablePageIDs(in: work, pageIDs: [pageID]).isEmpty {
        work = try PDFEditingEngine.commit(
          PDFTransaction([FlattenAnnotationsCommand(pageID: pageID)]), to: work, limits: limits)
      }
    }
    if plan.options.flattenFormFields, plan.inventory.formFieldCount > 0 {
      work = try PDFEditingEngine.commit(PDFTransaction([FlattenFormCommand()]), to: work, limits: limits)
    }
    work.version = plan.profile.pdfVersion
    for pageID in pageIDs {
      guard case .dictionary(var page)? = work.objects[pageID] else { continue }
      if plan.options.addMissingTrimBox && page[PDFName("TrimBox")] == nil {
        let fallback = page[PDFName("CropBox")] ?? page[PDFName("MediaBox")]
        if let fallback { page[PDFName("TrimBox")] = fallback }
      }
      work.objects[pageID] = .dictionary(page)
    }
    let icc = PDFXICCProfile.declaredCMYK()
    let iccID = nextObjectID(in: work)
    work.objects[iccID] = .stream(PDFStream(dictionary: [PDFName("N"): .integer(4), PDFName("Length"): .integer(Int64(icc.count))], bytes: icc))
    let intent: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("OutputIntent")),
      PDFName("S"): .name(PDFName("GTS_PDFX")),
      PDFName("OutputCondition"): .string(Data(PDFXICCProfile.conditionInfo.utf8)),
      PDFName("OutputConditionIdentifier"): .string(Data(PDFXICCProfile.conditionIdentifier.utf8)),
      PDFName("RegistryName"): .string(Data(PDFXICCProfile.registryName.utf8)),
      PDFName("Info"): .string(Data(PDFXICCProfile.conditionInfo.utf8)),
      PDFName("DestOutputProfile"): .reference(iccID),
    ]
    let xmpID = nextObjectID(in: work)
    work.objects[xmpID] = .stream(PDFStream(dictionary: [PDFName("Type"): .name(PDFName("Metadata")), PDFName("Subtype"): .name(PDFName("XML"))], bytes: Data(identificationXMP(profile: plan.profile).utf8)))
    if case .reference(let catalogID)? = work.trailer[PDFName("Root")], case .dictionary(var catalog)? = work.objects[catalogID] {
      catalog[PDFName("OutputIntents")] = .array([.dictionary(intent)])
      catalog[PDFName("Metadata")] = .reference(xmpID)
      work.objects[catalogID] = .dictionary(catalog)
    }
    return (work, plan)
  }

  public static func export(
    _ graph: PDFGraph, pageIDs: [PDFObjectID], profile: PDFXProfile,
    options: PDFXExportOptions = .printDelivery, limits: PDFLimits = PDFLimits()
  ) throws -> (data: Data, plan: PDFXExportPlan, validation: PDFXValidationResult) {
    let planned = plan(graph, pageIDs: pageIDs, profile: profile, options: options)
    guard planned.isExportable else {
      throw PDFError(.unsupported, planned.refusals.joined(separator: "; "))
    }
    let staged = try stage(plan: planned, graph: graph, pageIDs: pageIDs, limits: limits)
    let data = try PDFWriter.write(staged.graph)
    let validation = verify(data: data, profile: profile, options: options)
    guard validation.passed else {
      throw PDFError(.malformed, "PDF/X byte validation failed: " + validation.issues.joined(separator: "; "))
    }
    return (data, staged.plan, validation)
  }

  public static func verify(data: Data, profile: PDFXProfile, options: PDFXExportOptions = .printDelivery, limits: PDFLimits = PDFLimits()) -> PDFXValidationResult {
    var issues: [String] = []
    var checks: [String] = []
    guard let parsed = try? PDFParser.parse(data, limits: limits) else {
      return PDFXValidationResult(profile: profile, passed: false, issues: ["output does not parse"], checks: [])
    }
    checks.append("reparses as a PDF")
    let graph = parsed.graph
    let inventory = inventory(graph, pageIDs: parsed.pageIDs, profile: profile)
    for page in inventory.pages where page.trimBox == nil {
      issues.append("page \(page.pageIndex + 1) has no TrimBox")
    }
    if inventory.fontsNotEmbedded > 0 { issues.append("unembedded fonts remain") } else { checks.append("all fonts embedded") }
    if inventory.encrypted { issues.append("output is encrypted") }
    if inventory.transparencyUses > 0 && !profile.allowsTransparency { issues.append("transparency remains for PDF/X-1a") }
    if inventory.rgbContentUses > 0 && !profile.allowsRGB { issues.append("DeviceRGB content remains for PDF/X-1a") }
    if !inventory.hasOutputIntent || !inventory.outputIntentHasICC { issues.append("output intent with a valid ICC profile missing") } else { checks.append("output intent with ICC present") }
    if inventory.identifiedVersion != profile.identification { issues.append("PDF/X identification XMP missing or mismatched") } else { checks.append("identification XMP present") }
    if options.flattenAnnotations && inventory.annotationCount > 0 { issues.append("annotations remain after flatten") }
    if options.flattenFormFields && inventory.formFieldCount > 0 { issues.append("form fields remain after flatten") }
    checks.append("page boxes, fonts, output intent, identification and content rules inspected on saved bytes")
    return PDFXValidationResult(profile: profile, passed: issues.isEmpty, issues: issues, checks: checks)
  }

  static func catalogValue(_ key: String, in graph: PDFGraph) -> PDFValue? {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")], case .dictionary(let catalog)? = graph.objects[catalogID] else { return nil }
    return catalog[PDFName(key)]
  }

  static func xmpText(in graph: PDFGraph) -> String? {
    guard let value = catalogValue("Metadata", in: graph) else { return nil }
    let stream: PDFStream?
    if case .reference(let id) = value, case .stream(let resolved)? = graph.objects[id] { stream = resolved }
    else if case .stream(let direct) = value { stream = direct }
    else { stream = nil }
    guard let stream, let decoded = try? PDFFilters.decoded(stream) else { return nil }
    return String(decoding: decoded, as: UTF8.self)
  }

  static func verifiedICC(_ intent: [PDFName: PDFValue], in graph: PDFGraph) -> Bool {
    guard case .reference(let iccID)? = intent[PDFName("DestOutputProfile")], case .stream(let stream)? = graph.objects[iccID], let decoded = try? PDFFilters.decoded(stream) else { return false }
    guard decoded.count >= 132 else { return false }
    let bytes = [UInt8](decoded)
    let size = (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
    let signature = String(decoding: bytes[36..<40], as: UTF8.self)
    let colorSpace = String(decoding: bytes[16..<20], as: UTF8.self)
    return size == decoded.count && signature == "acsp" && colorSpace == "CMYK"
  }

  static func nextObjectID(in graph: PDFGraph) -> PDFObjectID {
    PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
  }

  static func identificationXMP(profile: PDFXProfile) -> String {
    """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"
        xmlns:pdf="http://ns.adobe.com/pdf/1.3/"
        xmlns:pdfxid="http://www.npes.org/pdfx/ns/id/">
       <dc:format>application/pdf</dc:format>
       <pdf:Producer>sPDF Editor PDF/X declared subset</pdf:Producer>
       <pdfxid:GTS_PDFXVersion>\(profile.identification)</pdfxid:GTS_PDFXVersion>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """
  }
}

